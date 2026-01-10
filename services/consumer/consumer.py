"""
Consumer + Post-Processor: Consumes frames from Kafka, sends to inference,
draws bounding boxes, and uploads to S3.

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
from datetime import datetime
from typing import List, Optional

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


# Settings
class Settings(BaseSettings):
    # Kafka settings
    kafka_bootstrap_servers: str = "localhost:9092"
    kafka_topic: str = "video-frames"
    kafka_group_id: str = "frame-consumer-group"
    kafka_auto_offset_reset: str = "earliest"
    
    # Inference settings
    inference_service_url: str = "http://inference-service:8000"
    inference_timeout: int = 30
    
    # S3 settings
    s3_bucket: str = "video-pipeline-output"
    s3_prefix: str = "annotated"
    aws_region: str = "us-east-1"
    
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
    """Processes frames: consumes from Kafka, runs inference, uploads to S3."""

    def __init__(self):
        self.running = False
        self.consumer: Optional[Consumer] = None
        self.http_client: Optional[httpx.Client] = None
        self.s3_client = None
        self.batch: List[dict] = []
        self.batch_start_time: Optional[float] = None
        self.frames_processed = 0
        self.batches_processed = 0

    def _init_kafka_consumer(self) -> Consumer:
        """Initialize Kafka consumer."""
        config = {
            "bootstrap.servers": settings.kafka_bootstrap_servers,
            "group.id": settings.kafka_group_id,
            "auto.offset.reset": settings.kafka_auto_offset_reset,
            "enable.auto.commit": False,
            "max.poll.interval.ms": 300000,
            "session.timeout.ms": 30000,
            "fetch.message.max.bytes": 10485760,
        }
        
        logger.info("Initializing Kafka consumer", config=config)
        consumer = Consumer(config)
        consumer.subscribe([settings.kafka_topic])
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
    def upload_to_s3(self, image_bytes: bytes, key: str):
        """Upload image to S3 with retry."""
        self.s3_client.put_object(
            Bucket=settings.s3_bucket,
            Key=key,
            Body=image_bytes,
            ContentType="image/jpeg",
        )
        logger.debug("Uploaded to S3", bucket=settings.s3_bucket, key=key)

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=1, max=10),
    )
    def call_inference_service(self, batch: List[dict]) -> InferenceResponse:
        """Call inference service with batch of frames."""
        # Prepare request payload
        frames = [
            {
                "frame_number": msg["frame_number"],
                "frame_data": msg["frame_data"],
                "timestamp": msg.get("timestamp"),
            }
            for msg in batch
        ]
        
        payload = {
            "stream_id": batch[0]["stream_id"],
            "frames": frames,
        }
        
        response = self.http_client.post("/predict", json=payload)
        response.raise_for_status()
        
        return InferenceResponse(**response.json())

    def process_batch(self, batch: List[dict]):
        """Process a batch of frames: inference + post-processing + S3 upload."""
        if not batch:
            return
        
        stream_id = batch[0]["stream_id"]
        start_time = time.time()
        
        logger.info(
            "Processing batch",
            stream_id=stream_id,
            batch_size=len(batch),
        )
        
        try:
            # Call inference service
            inference_response = self.call_inference_service(batch)
            
            # Process each frame result
            for i, result in enumerate(inference_response.results):
                frame_msg = batch[i]
                
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
                
                # Upload to S3
                self.upload_to_s3(image_bytes, s3_key)
            
            # Commit offsets after successful processing
            self.consumer.commit(asynchronous=False)
            
            processing_time = time.time() - start_time
            self.batches_processed += 1
            self.frames_processed += len(batch)
            
            logger.info(
                "Batch processed successfully",
                stream_id=stream_id,
                batch_size=len(batch),
                total_detections=inference_response.total_detections,
                inference_time_ms=inference_response.total_inference_time_ms,
                processing_time_seconds=processing_time,
                batches_processed=self.batches_processed,
            )
            
        except httpx.HTTPStatusError as e:
            logger.error(
                "Inference service error",
                status_code=e.response.status_code,
                detail=e.response.text,
            )
            raise
        except Exception as e:
            logger.error("Batch processing failed", error=str(e))
            raise

    def should_process_batch(self) -> bool:
        """Check if batch should be processed."""
        if len(self.batch) >= settings.batch_size:
            return True
        
        if self.batch_start_time and self.batch:
            elapsed = time.time() - self.batch_start_time
            if elapsed >= settings.batch_timeout_seconds:
                return True
        
        return False

    def start(self):
        """Start the consumer loop."""
        self.running = True
        self.consumer = self._init_kafka_consumer()
        self.http_client = self._init_http_client()
        self.s3_client = self._init_s3_client()
        
        logger.info(
            "Starting frame processor",
            kafka_topic=settings.kafka_topic,
            inference_url=settings.inference_service_url,
            s3_bucket=settings.s3_bucket,
            batch_size=settings.batch_size,
        )
        
        while self.running:
            try:
                # Poll for messages
                msg = self.consumer.poll(timeout=1.0)
                
                if msg is None:
                    # No message, check if batch should be flushed
                    if self.should_process_batch():
                        self.process_batch(self.batch)
                        self.batch = []
                        self.batch_start_time = None
                    continue
                
                if msg.error():
                    if msg.error().code() == KafkaError._PARTITION_EOF:
                        continue
                    logger.error("Kafka error", error=msg.error())
                    continue
                
                # Parse message
                try:
                    frame_msg = json.loads(msg.value().decode("utf-8"))
                except json.JSONDecodeError as e:
                    logger.warning("Invalid message format", error=str(e))
                    continue
                
                # Add to batch
                if not self.batch:
                    self.batch_start_time = time.time()
                
                self.batch.append(frame_msg)
                
                # Process batch if ready
                if self.should_process_batch():
                    self.process_batch(self.batch)
                    self.batch = []
                    self.batch_start_time = None
                
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
        
        # Process remaining batch
        if self.batch:
            try:
                self.process_batch(self.batch)
            except Exception as e:
                logger.error("Failed to process remaining batch", error=str(e))
        
        if self.consumer:
            self.consumer.close()
            logger.info("Kafka consumer closed")
        
        if self.http_client:
            self.http_client.close()
        
        logger.info(
            "Frame processor stopped",
            frames_processed=self.frames_processed,
            batches_processed=self.batches_processed,
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

