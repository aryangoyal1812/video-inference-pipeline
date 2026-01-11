"""
Frame Producer: Captures frames from RTSP stream and publishes to Kafka.

Supports publishing to multiple Kafka topics for dual-stream processing.

Usage:
    python producer.py --rtsp-url rtsp://localhost:8554/stream --kafka-bootstrap localhost:9092
"""

import argparse
import base64
import json
import os
import signal
import sys
import time
from datetime import datetime
from typing import List, Optional

import cv2
import logging
import numpy as np
import structlog
from confluent_kafka import Producer, KafkaException
from dotenv import load_dotenv

load_dotenv()

# Configure standard logging first (required for structlog filter_by_level)
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


class FrameProducer:
    """Captures frames from RTSP stream and publishes to multiple Kafka topics."""

    def __init__(
        self,
        rtsp_url: str,
        kafka_bootstrap: str,
        kafka_topics: List[str],
        frame_rate: int = 10,
        jpeg_quality: int = 85,
    ):
        self.rtsp_url = rtsp_url
        self.kafka_bootstrap = kafka_bootstrap
        self.kafka_topics = kafka_topics
        self.frame_rate = frame_rate
        self.jpeg_quality = jpeg_quality
        self.running = False
        self.producer: Optional[Producer] = None
        self.cap: Optional[cv2.VideoCapture] = None
        self.frame_count = 0
        self.stream_id = self._generate_stream_id()

        logger.info(
            "FrameProducer initialized",
            rtsp_url=rtsp_url,
            kafka_topics=kafka_topics,
            num_topics=len(kafka_topics),
            frame_rate=frame_rate,
            stream_id=self.stream_id,
        )

    def _generate_stream_id(self) -> str:
        """Generate a unique stream ID based on RTSP URL."""
        import hashlib
        url_hash = hashlib.md5(self.rtsp_url.encode()).hexdigest()[:8]
        return f"stream_{url_hash}"

    def _init_kafka_producer(self) -> Producer:
        """Initialize Kafka producer with configuration."""
        config = {
            "bootstrap.servers": self.kafka_bootstrap,
            "client.id": f"frame-producer-{self.stream_id}",
            "acks": "all",
            "retries": 3,
            "retry.backoff.ms": 1000,
            "message.max.bytes": 10485760,  # 10MB max message size
            "compression.type": "lz4",
            "linger.ms": 5,
            "batch.size": 1048576,  # 1MB batch size
        }
        
        logger.info("Initializing Kafka producer", config=config)
        return Producer(config)

    def _init_video_capture(self) -> cv2.VideoCapture:
        """Initialize video capture from RTSP stream."""
        logger.info("Connecting to RTSP stream", url=self.rtsp_url)
        
        cap = cv2.VideoCapture(self.rtsp_url, cv2.CAP_FFMPEG)
        
        if not cap.isOpened():
            raise RuntimeError(f"Failed to open RTSP stream: {self.rtsp_url}")
        
        # Get stream properties
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        fps = cap.get(cv2.CAP_PROP_FPS)
        
        logger.info(
            "RTSP stream connected",
            width=width,
            height=height,
            fps=fps,
        )
        
        return cap

    def _encode_frame(self, frame: np.ndarray) -> str:
        """Encode frame to base64 JPEG."""
        encode_params = [cv2.IMWRITE_JPEG_QUALITY, self.jpeg_quality]
        _, buffer = cv2.imencode(".jpg", frame, encode_params)
        return base64.b64encode(buffer).decode("utf-8")

    def _delivery_callback(self, err, msg):
        """Callback for Kafka message delivery."""
        if err:
            logger.error(
                "Message delivery failed",
                error=str(err),
                topic=msg.topic(),
            )
        else:
            logger.debug(
                "Message delivered",
                topic=msg.topic(),
                partition=msg.partition(),
                offset=msg.offset(),
            )

    def _publish_frame(self, frame: np.ndarray, timestamp: datetime):
        """Publish a single frame to ALL configured Kafka topics."""
        try:
            # Encode frame once (shared across all topics)
            frame_b64 = self._encode_frame(frame)
            
            # Create message payload (same stream_id for all topics)
            message = {
                "stream_id": self.stream_id,
                "frame_number": self.frame_count,
                "timestamp": timestamp.isoformat(),
                "width": frame.shape[1],
                "height": frame.shape[0],
                "frame_data": frame_b64,
            }
            
            # Serialize to JSON
            payload = json.dumps(message).encode("utf-8")
            
            # Publish to ALL Kafka topics
            for topic in self.kafka_topics:
                self.producer.produce(
                    topic=topic,
                    key=self.stream_id.encode("utf-8"),
                    value=payload,
                    callback=self._delivery_callback,
                )
            
            # Trigger any available delivery callbacks
            self.producer.poll(0)
            
            self.frame_count += 1
            
            if self.frame_count % 100 == 0:
                logger.info(
                    "Frames published",
                    frame_count=self.frame_count,
                    stream_id=self.stream_id,
                    topics=self.kafka_topics,
                )
                
        except KafkaException as e:
            logger.error("Failed to publish frame", error=str(e))
            raise

    def start(self):
        """Start capturing and publishing frames."""
        self.running = True
        self.producer = self._init_kafka_producer()
        
        # Retry connection with backoff
        max_retries = 5
        retry_count = 0
        
        while retry_count < max_retries and self.running:
            try:
                self.cap = self._init_video_capture()
                break
            except RuntimeError as e:
                retry_count += 1
                wait_time = 2 ** retry_count
                logger.warning(
                    "Failed to connect to RTSP stream, retrying",
                    error=str(e),
                    retry_count=retry_count,
                    wait_time=wait_time,
                )
                time.sleep(wait_time)
        
        if not self.cap or not self.cap.isOpened():
            raise RuntimeError("Failed to connect to RTSP stream after retries")
        
        # Calculate frame interval
        frame_interval = 1.0 / self.frame_rate
        last_frame_time = 0
        
        logger.info(
            "Starting frame capture loop",
            frame_rate=self.frame_rate,
            topics=self.kafka_topics,
        )
        
        while self.running:
            try:
                current_time = time.time()
                
                # Rate limiting
                if current_time - last_frame_time < frame_interval:
                    # Read and discard frames to keep buffer fresh
                    self.cap.grab()
                    continue
                
                ret, frame = self.cap.read()
                
                if not ret:
                    logger.warning("Failed to read frame, attempting reconnection")
                    self.cap.release()
                    time.sleep(1)
                    self.cap = self._init_video_capture()
                    continue
                
                timestamp = datetime.utcnow()
                self._publish_frame(frame, timestamp)
                last_frame_time = current_time
                
            except KeyboardInterrupt:
                logger.info("Received interrupt, stopping")
                break
            except Exception as e:
                logger.error("Error in capture loop", error=str(e))
                time.sleep(1)
        
        self.stop()

    def stop(self):
        """Stop the producer and cleanup resources."""
        self.running = False
        
        if self.cap:
            self.cap.release()
            logger.info("Video capture released")
        
        if self.producer:
            # Flush any remaining messages
            remaining = self.producer.flush(timeout=10)
            if remaining > 0:
                logger.warning("Some messages were not delivered", remaining=remaining)
            logger.info("Kafka producer flushed")
        
        logger.info(
            "Producer stopped",
            total_frames=self.frame_count,
            stream_id=self.stream_id,
            topics=self.kafka_topics,
        )


def parse_topics(topics_str: str) -> List[str]:
    """Parse comma-separated topics string into a list."""
    if not topics_str:
        return ["video-frames"]
    return [t.strip() for t in topics_str.split(",") if t.strip()]


def main():
    parser = argparse.ArgumentParser(description="Frame Producer - RTSP to Kafka")
    parser.add_argument(
        "--rtsp-url",
        type=str,
        default=os.getenv("RTSP_URL", "rtsp://localhost:8554/stream"),
        help="RTSP stream URL",
    )
    parser.add_argument(
        "--kafka-bootstrap",
        type=str,
        default=os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092"),
        help="Kafka bootstrap servers",
    )
    parser.add_argument(
        "--kafka-topics",
        type=str,
        default=os.getenv("KAFKA_TOPICS", os.getenv("KAFKA_TOPIC", "video-frames-1,video-frames-2")),
        help="Comma-separated list of Kafka topics for frames",
    )
    parser.add_argument(
        "--frame-rate",
        type=int,
        default=int(os.getenv("FRAME_RATE", "10")),
        help="Target frame rate (frames per second)",
    )
    parser.add_argument(
        "--jpeg-quality",
        type=int,
        default=int(os.getenv("JPEG_QUALITY", "85")),
        help="JPEG encoding quality (0-100)",
    )
    
    args = parser.parse_args()
    
    # Parse topics from comma-separated string
    kafka_topics = parse_topics(args.kafka_topics)
    
    logger.info(
        "Starting producer with configuration",
        rtsp_url=args.rtsp_url,
        kafka_bootstrap=args.kafka_bootstrap,
        kafka_topics=kafka_topics,
    )
    
    producer = FrameProducer(
        rtsp_url=args.rtsp_url,
        kafka_bootstrap=args.kafka_bootstrap,
        kafka_topics=kafka_topics,
        frame_rate=args.frame_rate,
        jpeg_quality=args.jpeg_quality,
    )
    
    # Handle graceful shutdown
    def signal_handler(sig, frame):
        logger.info("Shutdown signal received")
        producer.stop()
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    producer.start()


if __name__ == "__main__":
    main()
