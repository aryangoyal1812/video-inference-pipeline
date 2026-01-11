"""
Consumer + Post-Processor: Consumes frames from multiple Kafka topics, sends to inference,
draws bounding boxes, and uploads to topic-specific S3 buckets.

Supports dual-stream PARALLEL processing with separate S3 bucket routing per topic.

Usage:
    python consumer.py
"""

import base64
import io
import json
import logging
import os
import signal
import sys
import time
from concurrent.futures import ThreadPoolExecutor, Future, as_completed
from datetime import datetime
from threading import Lock
from typing import Dict, List, Optional

import boto3
import cv2
import httpx
import numpy as np
import structlog
from botocore.config import Config as BotoConfig
from confluent_kafka import Consumer, KafkaError, KafkaException
from PIL import Image, ImageDraw, ImageFont
from pydantic import BaseModel
from pydantic_settings import BaseSettings
from tenacity import retry, stop_after_attempt, wait_exponential

# Configure standard logging first (required for structlog filter_by_level).
logging.basicConfig(
    format="%(message)s",
    stream=sys.stdout,
    level=logging.INFO,
)

# Configure structured logging
structlog.configure(
    processors=[
        structlog.stdlib.filter_by_level,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer()
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    context_class=dict,
    logger_factory=structlog.stdlib.LoggerFactory(),
)

logger = structlog.get_logger(__name__)


def parse_topics(topics_str: str) -> List[str]:
    """Parse comma-separated topics string into a list."""
    if not topics_str:
        return ["video-frames"]
    return [t.strip() for t in topics_str.split(",") if t.strip()]


def parse_topic_bucket_mapping(mapping_str: str, topics: List[str], default_bucket: str) -> Dict[str, str]:
    """
    Parse topic-to-bucket mapping from JSON string or environment variables.
    
    Supports two formats:
    1. JSON: '{"video-frames-1": "bucket-1", "video-frames-2": "bucket-2"}'
    2. Environment variables: S3_BUCKET_1, S3_BUCKET_2 (matched by topic index)
    """
    if mapping_str:
        try:
            return json.loads(mapping_str)
        except json.JSONDecodeError:
            logger.warning("Invalid TOPIC_BUCKET_MAPPING JSON, falling back to env vars")
    
    # Fall back to indexed environment variables
    mapping = {}
    for i, topic in enumerate(topics):
        bucket_env = f"S3_BUCKET_{i + 1}"
        bucket = os.getenv(bucket_env, default_bucket)
        mapping[topic] = bucket
    
    return mapping


# Settings
class Settings(BaseSettings):
    # Kafka settings
    kafka_bootstrap_servers: str = "localhost:9092"
    kafka_topics: str = "video-frames-1,video-frames-2"  # Comma-separated
    kafka_group_id: str = "frame-consumer-group"
    kafka_auto_offset_reset: str = "earliest"
    
    # Inference settings
    inference_service_url: str = "http://inference-service:8000"
    inference_timeout: int = 30
    
    # S3 settings (defaults)
    s3_bucket: str = "video-pipeline-output"  # Default/fallback bucket
    s3_prefix: str = "annotated"
    aws_region: str = "us-east-1"
    
    # Topic to bucket mapping (JSON string)
    topic_bucket_mapping: str = ""
    
    # Processing settings
    batch_size: int = 25
    batch_timeout_seconds: float = 5.0
    
    class Config:
        env_prefix = ""


settings = Settings()


# Pydantic models for inference response
class BoundingBox(BaseModel):
    x1: float
    y1: float
    x2: float
    y2: float
    confidence: float
    class_id: int
    class_name: str


class FrameResult(BaseModel):
    frame_number: int
    detections: List[BoundingBox]
    inference_time_ms: float


class InferenceResponse(BaseModel):
    stream_id: str
    results: List[FrameResult]
    total_frames: int
    total_detections: int
    total_inference_time_ms: float


# Color palette for bounding boxes (BGR format)
COLORS = [
    (255, 0, 0),      # Blue
    (0, 255, 0),      # Green
    (0, 0, 255),      # Red
    (255, 255, 0),    # Cyan
    (255, 0, 255),    # Magenta
    (0, 255, 255),    # Yellow
    (128, 0, 255),    # Orange
    (255, 128, 0),    # Light Blue
    (0, 128, 255),    # Light Orange
    (128, 255, 0),    # Light Green
]


class FrameProcessor:
    """Processes frames from multiple topics IN PARALLEL: consumes from Kafka, runs inference, uploads to S3."""

    def __init__(self):
        self.running = False
        self.consumer: Optional[Consumer] = None
        self.http_client: Optional[httpx.Client] = None
        self.s3_client = None
        
        # Parse topics
        self.topics = parse_topics(settings.kafka_topics)
        
        # Parse topic-to-bucket mapping
        self.topic_bucket_mapping = parse_topic_bucket_mapping(
            settings.topic_bucket_mapping,
            self.topics,
            settings.s3_bucket
        )
        
        # Maintain separate batches per topic
        self.batches: Dict[str, List[dict]] = {topic: [] for topic in self.topics}
        self.batch_start_times: Dict[str, Optional[float]] = {topic: None for topic in self.topics}
        self.batch_locks: Dict[str, Lock] = {topic: Lock() for topic in self.topics}
        
        # Track which topics have pending batch processing
        self.pending_batches: Dict[str, bool] = {topic: False for topic in self.topics}
        
        # ThreadPoolExecutor for parallel batch processing (one worker per topic)
        self.executor: Optional[ThreadPoolExecutor] = None
        self.pending_futures: List[Future] = []
        
        # Statistics (thread-safe)
        self.stats_lock = Lock()
        self.frames_processed = 0
        self.batches_processed = 0
        self.frames_per_topic: Dict[str, int] = {topic: 0 for topic in self.topics}
        
        logger.info(
            "FrameProcessor initialized (PARALLEL mode)",
            topics=self.topics,
            topic_bucket_mapping=self.topic_bucket_mapping,
            max_workers=len(self.topics),
        )

    def _init_kafka_consumer(self) -> Consumer:
        """Initialize Kafka consumer subscribing to multiple topics."""
        config = {
            "bootstrap.servers": settings.kafka_bootstrap_servers,
            "group.id": settings.kafka_group_id,
            "auto.offset.reset": settings.kafka_auto_offset_reset,
            "enable.auto.commit": False,
            "max.poll.interval.ms": 300000,
            "session.timeout.ms": 30000,
            "fetch.message.max.bytes": 10485760,
        }
        
        logger.info("Initializing Kafka consumer", config=config, topics=self.topics)
        consumer = Consumer(config)
        consumer.subscribe(self.topics)  # Subscribe to ALL topics
        return consumer

    def _init_http_client(self) -> httpx.Client:
        """Initialize HTTP client for inference service."""
        return httpx.Client(
            base_url=settings.inference_service_url,
            timeout=settings.inference_timeout,
        )

    def _init_s3_client(self):
        """Initialize S3 client."""
        boto_config = BotoConfig(
            region_name=settings.aws_region,
            retries={"max_attempts": 3, "mode": "adaptive"},
        )
        return boto3.client("s3", config=boto_config)

    def decode_frame(self, frame_data: str) -> np.ndarray:
        """Decode base64 frame to numpy array."""
        image_bytes = base64.b64decode(frame_data)
        image = Image.open(io.BytesIO(image_bytes))
        return cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)

    def draw_bounding_boxes(
        self,
        frame: np.ndarray,
        detections: List[BoundingBox]
    ) -> np.ndarray:
        """Draw bounding boxes on frame."""
        annotated = frame.copy()
        
        for det in detections:
            # Get color based on class ID
            color = COLORS[det.class_id % len(COLORS)]
            
            # Draw bounding box
            x1, y1 = int(det.x1), int(det.y1)
            x2, y2 = int(det.x2), int(det.y2)
            cv2.rectangle(annotated, (x1, y1), (x2, y2), color, 2)
            
            # Draw label background
            label = f"{det.class_name}: {det.confidence:.2f}"
            (label_width, label_height), baseline = cv2.getTextSize(
                label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1
            )
            cv2.rectangle(
                annotated,
                (x1, y1 - label_height - baseline - 5),
                (x1 + label_width, y1),
                color,
                -1,
            )
            
            # Draw label text
            cv2.putText(
                annotated,
                label,
                (x1, y1 - baseline - 2),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.5,
                (255, 255, 255),
                1,
            )
        
        return annotated

    def encode_frame(self, frame: np.ndarray) -> bytes:
        """Encode frame to JPEG bytes."""
        _, buffer = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 90])
        return buffer.tobytes()

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=1, max=10),
    )
    def upload_to_s3(self, image_bytes: bytes, key: str, bucket: str):
        """Upload image to S3 with retry."""
        self.s3_client.put_object(
            Bucket=bucket,
            Key=key,
            Body=image_bytes,
            ContentType="image/jpeg",
        )
        logger.debug("Uploaded to S3", bucket=bucket, key=key)

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=1, max=10),
    )
    def call_inference_service_chunk(self, chunk: List[dict], stream_id: str) -> InferenceResponse:
        """Call inference service with a single chunk of frames (max 25)."""
        frames = [
            {
                "frame_number": msg["frame_number"],
                "frame_data": msg["frame_data"],
                "timestamp": msg.get("timestamp"),
            }
            for msg in chunk
        ]
        
        payload = {
            "stream_id": stream_id,
            "frames": frames,
        }
        
        response = self.http_client.post("/predict", json=payload)
        response.raise_for_status()
        
        return InferenceResponse(**response.json())

    def call_inference_service(self, batch: List[dict]) -> List[tuple]:
        """Call inference service, splitting into chunks if needed. Returns list of (chunk, response) tuples."""
        if not batch:
            return []
        
        stream_id = batch[0]["stream_id"]
        max_chunk_size = 25  # Inference service limit
        
        results = []
        for i in range(0, len(batch), max_chunk_size):
            chunk = batch[i:i + max_chunk_size]
            response = self.call_inference_service_chunk(chunk, stream_id)
            results.append((chunk, response))
        
        return results

    def process_batch(self, batch: List[dict], topic: str) -> bool:
        """
        Process a batch of frames: inference + post-processing + S3 upload.
        Thread-safe: can be called from multiple threads simultaneously.
        Returns True on success, False on failure.
        """
        if not batch:
            return True
        
        stream_id = batch[0]["stream_id"]
        bucket = self.topic_bucket_mapping.get(topic, settings.s3_bucket)
        start_time = time.time()
        total_detections = 0
        total_inference_time = 0.0
        batch_size = len(batch)
        
        logger.info(
            "Processing batch (parallel)",
            topic=topic,
            stream_id=stream_id,
            batch_size=batch_size,
            target_bucket=bucket,
        )
        
        try:
            # Call inference service (handles chunking internally for batches > 25)
            chunk_results = self.call_inference_service(batch)
            
            # Process each chunk result
            for chunk, inference_response in chunk_results:
                total_detections += inference_response.total_detections
                total_inference_time += inference_response.total_inference_time_ms
                
                for i, result in enumerate(inference_response.results):
                    frame_msg = chunk[i]
                    
                    # Skip frames with no detections
                    if not result.detections:
                        continue
                    
                    # Decode frame
                    frame = self.decode_frame(frame_msg["frame_data"])
                    
                    # Draw bounding boxes
                    annotated_frame = self.draw_bounding_boxes(frame, result.detections)
                    
                    # Encode annotated frame
                    image_bytes = self.encode_frame(annotated_frame)
                    
                    # Generate S3 key
                    timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
                    s3_key = (
                        f"{settings.s3_prefix}/{stream_id}/"
                        f"{timestamp}_frame{result.frame_number}.jpg"
                    )
                    
                    # Upload to topic-specific S3 bucket
                    self.upload_to_s3(image_bytes, s3_key, bucket)
            
            processing_time = time.time() - start_time
            
            # Update stats thread-safely
            with self.stats_lock:
                self.batches_processed += 1
                self.frames_processed += batch_size
                self.frames_per_topic[topic] += batch_size
                current_batches = self.batches_processed
            
            logger.info(
                "Batch processed successfully (parallel)",
                topic=topic,
                stream_id=stream_id,
                batch_size=batch_size,
                target_bucket=bucket,
                total_detections=total_detections,
                inference_time_ms=total_inference_time,
                processing_time_seconds=processing_time,
                batches_processed=current_batches,
            )
            
            return True
            
        except httpx.HTTPStatusError as e:
            logger.error(
                "Inference service error",
                topic=topic,
                status_code=e.response.status_code,
                detail=e.response.text,
            )
            return False
        except Exception as e:
            logger.error("Batch processing failed", topic=topic, error=str(e))
            return False
        finally:
            # Mark this topic as no longer having a pending batch
            self.pending_batches[topic] = False

    def should_process_batch(self, topic: str) -> bool:
        """Check if batch for a specific topic should be processed."""
        batch = self.batches[topic]
        batch_start_time = self.batch_start_times[topic]
        
        if len(batch) >= settings.batch_size:
            return True
        
        if batch_start_time and batch:
            elapsed = time.time() - batch_start_time
            if elapsed >= settings.batch_timeout_seconds:
                return True
        
        return False

    def submit_batch_for_processing(self, topic: str):
        """Submit a batch for parallel processing if not already pending."""
        if self.pending_batches[topic]:
            # Already processing this topic, skip
            return
        
        batch = self.batches[topic]
        if not batch:
            return
        
        # Mark as pending and clear the batch
        self.pending_batches[topic] = True
        self.batches[topic] = []
        self.batch_start_times[topic] = None
        
        # Submit to thread pool
        future = self.executor.submit(self.process_batch, batch, topic)
        self.pending_futures.append((future, topic))
        
        logger.debug("Submitted batch for parallel processing", topic=topic, batch_size=len(batch))

    def check_and_submit_timeouts(self):
        """Check all topic batches for timeouts and submit for processing if needed."""
        for topic in self.topics:
            if self.should_process_batch(topic) and self.batches[topic]:
                self.submit_batch_for_processing(topic)

    def cleanup_completed_futures(self):
        """Clean up completed futures and commit offsets."""
        completed = []
        still_pending = []
        
        for future, topic in self.pending_futures:
            if future.done():
                completed.append((future, topic))
            else:
                still_pending.append((future, topic))
        
        self.pending_futures = still_pending
        
        # If any futures completed, commit offsets
        if completed:
            try:
                self.consumer.commit(asynchronous=False)
            except Exception as e:
                logger.error("Failed to commit offsets", error=str(e))

    def start(self):
        """Start the consumer loop with PARALLEL batch processing."""
        self.running = True
        self.consumer = self._init_kafka_consumer()
        self.http_client = self._init_http_client()
        self.s3_client = self._init_s3_client()
        
        # Create ThreadPoolExecutor with one worker per topic for true parallelism
        self.executor = ThreadPoolExecutor(max_workers=len(self.topics), thread_name_prefix="batch-processor")
        
        logger.info(
            "Starting frame processor (PARALLEL mode)",
            kafka_topics=self.topics,
            topic_bucket_mapping=self.topic_bucket_mapping,
            inference_url=settings.inference_service_url,
            batch_size=settings.batch_size,
            parallel_workers=len(self.topics),
        )
        
        while self.running:
            try:
                # Clean up completed futures periodically
                self.cleanup_completed_futures()
                
                # Poll for messages
                msg = self.consumer.poll(timeout=0.5)
                
                if msg is None:
                    # No message, check if any batches should be flushed due to timeout
                    self.check_and_submit_timeouts()
                    continue
                
                if msg.error():
                    if msg.error().code() == KafkaError._PARTITION_EOF:
                        continue
                    logger.error("Kafka error", error=msg.error())
                    continue
                
                # Get the topic this message came from
                topic = msg.topic()
                
                # Parse message
                try:
                    frame_msg = json.loads(msg.value().decode("utf-8"))
                    frame_msg["_topic"] = topic
                except json.JSONDecodeError as e:
                    logger.warning("Invalid message format", topic=topic, error=str(e))
                    continue
                
                # Add to topic-specific batch (only if not currently processing)
                if not self.pending_batches[topic]:
                    if not self.batches[topic]:
                        self.batch_start_times[topic] = time.time()
                    self.batches[topic].append(frame_msg)
                    
                    # Submit batch if ready
                    if self.should_process_batch(topic):
                        self.submit_batch_for_processing(topic)
                
            except KeyboardInterrupt:
                logger.info("Received interrupt, stopping")
                break
            except Exception as e:
                logger.error("Error in consumer loop", error=str(e))
                time.sleep(1)
        
        self.stop()

    def stop(self):
        """Stop the consumer and cleanup."""
        self.running = False
        logger.info("Stopping frame processor...")
        
        # Wait for pending futures to complete
        if self.pending_futures:
            logger.info("Waiting for pending batch processing to complete", pending_count=len(self.pending_futures))
            for future, topic in self.pending_futures:
                try:
                    future.result(timeout=30)
                except Exception as e:
                    logger.error("Pending batch failed", topic=topic, error=str(e))
        
        # Process remaining batches for all topics
        for topic in self.topics:
            if self.batches[topic]:
                logger.info("Processing remaining batch", topic=topic, batch_size=len(self.batches[topic]))
                try:
                    self.process_batch(self.batches[topic], topic)
                except Exception as e:
                    logger.error("Failed to process remaining batch", topic=topic, error=str(e))
        
        # Shutdown thread pool
        if self.executor:
            self.executor.shutdown(wait=True)
            logger.info("Thread pool shutdown complete")
        
        # Final offset commit
        if self.consumer:
            try:
                self.consumer.commit(asynchronous=False)
            except Exception:
                pass
            self.consumer.close()
            logger.info("Kafka consumer closed")
        
        if self.http_client:
            self.http_client.close()
        
        logger.info(
            "Frame processor stopped",
            frames_processed=self.frames_processed,
            batches_processed=self.batches_processed,
            frames_per_topic=self.frames_per_topic,
        )


def main():
    processor = FrameProcessor()
    
    # Handle graceful shutdown
    def signal_handler(sig, frame):
        logger.info("Shutdown signal received")
        processor.stop()
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    processor.start()


if __name__ == "__main__":
    main()
