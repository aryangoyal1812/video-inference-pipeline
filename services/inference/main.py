"""
Inference Service: FastAPI-based object detection using YOLOv8.

Endpoints:
    POST /predict - Run inference on a batch of frames
    GET /health - Health check
    GET /metrics - Prometheus metrics
"""

import base64
import io
import logging
import sys
import time
from contextlib import asynccontextmanager
from typing import List, Optional

import cv2
import numpy as np
import structlog
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from PIL import Image
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings
from starlette.responses import Response
from ultralytics import YOLO

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
    model_name: str = "yolov8n.pt"  # Nano model for CPU
    confidence_threshold: float = 0.5
    max_batch_size: int = 25
    model_device: str = "cpu"

    class Config:
        env_prefix = "INFERENCE_"


settings = Settings()

# Prometheus metrics
INFERENCE_REQUESTS = Counter(
    "inference_requests_total",
    "Total number of inference requests",
    ["status"]
)
INFERENCE_LATENCY = Histogram(
    "inference_latency_seconds",
    "Inference request latency",
    buckets=[0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
)
FRAMES_PROCESSED = Counter(
    "frames_processed_total",
    "Total number of frames processed"
)
DETECTIONS_TOTAL = Counter(
    "detections_total",
    "Total number of objects detected",
    ["class_name"]
)


# Pydantic models
class FrameInput(BaseModel):
    """Single frame input."""
    frame_number: int
    frame_data: str = Field(..., description="Base64 encoded JPEG image")
    timestamp: Optional[str] = None


class BatchInferenceRequest(BaseModel):
    """Batch inference request."""
    stream_id: str
    frames: List[FrameInput] = Field(..., min_length=1, max_length=25)


class BoundingBox(BaseModel):
    """Single bounding box detection."""
    x1: float
    y1: float
    x2: float
    y2: float
    confidence: float
    class_id: int
    class_name: str


class FrameResult(BaseModel):
    """Inference result for a single frame."""
    frame_number: int
    detections: List[BoundingBox]
    inference_time_ms: float


class BatchInferenceResponse(BaseModel):
    """Batch inference response."""
    stream_id: str
    results: List[FrameResult]
    total_frames: int
    total_detections: int
    total_inference_time_ms: float


# Global model instance
model: Optional[YOLO] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler."""
    global model
    
    logger.info("Loading YOLO model", model_name=settings.model_name)
    start_time = time.time()
    
    try:
        model = YOLO(settings.model_name)
        model.to(settings.model_device)
        
        # Warm up the model
        dummy_input = np.zeros((640, 640, 3), dtype=np.uint8)
        model.predict(dummy_input, verbose=False)
        
        load_time = time.time() - start_time
        logger.info("Model loaded successfully", load_time_seconds=load_time)
        
    except Exception as e:
        logger.error("Failed to load model", error=str(e))
        raise
    
    yield
    
    logger.info("Shutting down inference service")


# FastAPI app
app = FastAPI(
    title="Video Inference Service",
    description="Object detection inference using YOLOv8",
    version="1.0.0",
    lifespan=lifespan,
)


def decode_frame(frame_data: str) -> np.ndarray:
    """Decode base64 frame to numpy array."""
    try:
        image_bytes = base64.b64decode(frame_data)
        image = Image.open(io.BytesIO(image_bytes))
        return cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
    except Exception as e:
        logger.error("Failed to decode frame", error=str(e))
        raise ValueError(f"Invalid frame data: {str(e)}")


def run_inference(frame: np.ndarray) -> tuple[List[BoundingBox], float]:
    """Run inference on a single frame."""
    start_time = time.time()
    
    results = model.predict(
        frame,
        conf=settings.confidence_threshold,
        verbose=False,
    )[0]
    
    inference_time = (time.time() - start_time) * 1000  # Convert to ms
    
    detections = []
    for box in results.boxes:
        x1, y1, x2, y2 = box.xyxy[0].tolist()
        confidence = float(box.conf[0])
        class_id = int(box.cls[0])
        class_name = results.names[class_id]
        
        detections.append(BoundingBox(
            x1=x1,
            y1=y1,
            x2=x2,
            y2=y2,
            confidence=confidence,
            class_id=class_id,
            class_name=class_name,
        ))
        
        # Update metrics
        DETECTIONS_TOTAL.labels(class_name=class_name).inc()
    
    return detections, inference_time


@app.post("/predict", response_model=BatchInferenceResponse)
async def predict_batch(request: BatchInferenceRequest):
    """
    Run object detection on a batch of frames.
    
    Accepts up to 25 frames encoded as base64 JPEG images.
    Returns bounding box coordinates for detected objects.
    """
    start_time = time.time()
    
    try:
        if len(request.frames) > settings.max_batch_size:
            raise HTTPException(
                status_code=400,
                detail=f"Batch size exceeds maximum of {settings.max_batch_size}"
            )
        
        results = []
        total_detections = 0
        
        for frame_input in request.frames:
            try:
                # Decode frame
                frame = decode_frame(frame_input.frame_data)
                
                # Run inference
                detections, inference_time = run_inference(frame)
                
                results.append(FrameResult(
                    frame_number=frame_input.frame_number,
                    detections=detections,
                    inference_time_ms=inference_time,
                ))
                
                total_detections += len(detections)
                FRAMES_PROCESSED.inc()
                
            except ValueError as e:
                logger.warning(
                    "Skipping invalid frame",
                    frame_number=frame_input.frame_number,
                    error=str(e),
                )
                results.append(FrameResult(
                    frame_number=frame_input.frame_number,
                    detections=[],
                    inference_time_ms=0,
                ))
        
        total_time = (time.time() - start_time) * 1000
        
        INFERENCE_REQUESTS.labels(status="success").inc()
        INFERENCE_LATENCY.observe(total_time / 1000)
        
        logger.info(
            "Batch inference completed",
            stream_id=request.stream_id,
            frames_processed=len(request.frames),
            total_detections=total_detections,
            total_time_ms=total_time,
        )
        
        return BatchInferenceResponse(
            stream_id=request.stream_id,
            results=results,
            total_frames=len(request.frames),
            total_detections=total_detections,
            total_inference_time_ms=total_time,
        )
        
    except HTTPException:
        INFERENCE_REQUESTS.labels(status="error").inc()
        raise
    except Exception as e:
        INFERENCE_REQUESTS.labels(status="error").inc()
        logger.error("Inference failed", error=str(e))
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/health")
async def health_check():
    """Health check endpoint."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    
    return {
        "status": "healthy",
        "model": settings.model_name,
        "device": settings.model_device,
    }


@app.get("/ready")
async def readiness_check():
    """Readiness check endpoint."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model not ready")
    
    return {"status": "ready"}


@app.get("/metrics")
async def metrics():
    """Prometheus metrics endpoint."""
    return Response(
        content=generate_latest(),
        media_type=CONTENT_TYPE_LATEST,
    )


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    """Global exception handler."""
    logger.error(
        "Unhandled exception",
        path=request.url.path,
        method=request.method,
        error=str(exc),
    )
    return JSONResponse(
        status_code=500,
        content={"detail": "Internal server error"},
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        workers=1,  # Single worker for CPU inference
        log_level="info",
    )

