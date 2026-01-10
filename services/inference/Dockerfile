FROM python:3.11-slim

WORKDIR /app

# Install system dependencies (libgl1 replaces libgl1-mesa-glx in Debian Trixie)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip and install requirements with retry
COPY requirements.txt .
RUN pip install --upgrade pip && \
    pip install --no-cache-dir --timeout 120 --retries 3 -r requirements.txt

# Download YOLO model during build
RUN python -c "from ultralytics import YOLO; model = YOLO('yolov8n.pt'); print('Model loaded:', model)"

# Copy application code
COPY main.py .

# Create non-root user
RUN useradd -m -u 1000 appuser && \
    chown -R appuser:appuser /app
USER appuser

# Expose port
EXPOSE 8000

# Health check (increased start period for model loading)
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
    CMD curl -f http://localhost:8000/health || exit 1

# Run the application
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]

