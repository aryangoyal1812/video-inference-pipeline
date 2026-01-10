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
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY consumer.py .

# Create non-root user
RUN useradd -m -u 1000 appuser
USER appuser

# Health check (consumer doesn't expose HTTP, so we check process)
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python -c "import confluent_kafka; import boto3; print('healthy')" || exit 1

ENTRYPOINT ["python", "consumer.py"]

