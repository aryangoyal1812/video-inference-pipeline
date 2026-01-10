# Quick Start Guide

## 🖥️ Local Testing (5 minutes)

### Prerequisites
- Docker & Docker Compose installed

### Steps

```bash
# 1. Start all services (Kafka, LocalStack S3, RTSP, Inference, Consumer)
./scripts/local-test.sh up

# 2. Wait ~60 seconds for YOLO model to load, then verify
curl http://localhost:8000/health

# 3. Start the producer to begin video processing
./scripts/local-test.sh producer

# 4. In another terminal, watch the consumer process frames
./scripts/local-test.sh logs consumer

# 5. Check annotated images in S3
./scripts/local-test.sh s3-list

# 6. Download and view a processed image
./scripts/local-test.sh s3-download

# 7. When done
./scripts/local-test.sh down
```

---

## 🔍 Verify the Pipeline

```bash
# Check all service status
./scripts/local-test.sh status

# Expected output:
#   Inference API:  ✅ http://localhost:8000
#   LocalStack S3:  ✅ http://localhost:4566
#   Kafka:          ✅ localhost:9092
#   RTSP Stream:    ✅ rtsp://localhost:8554/stream
#   Kafka Messages: 1234 frames in topic
#   S3 Images:      500 annotated images
```

---

## 🚀 AWS Deployment (30 minutes)

### Prerequisites
- AWS Account with CLI configured (`aws configure`)
- kubectl installed
- Terraform installed

### Steps

```bash
# 1. Generate SSH key for RTSP server
cd terraform
ssh-keygen -t rsa -b 4096 -f rtsp-key -N ""
cd ..

# 2. Deploy everything
./scripts/deploy.sh full

# 3. Check deployment
./scripts/deploy.sh status

# 4. Start the producer
KAFKA_BOOTSTRAP=$(terraform -chdir=terraform output -raw msk_bootstrap_brokers)
RTSP_IP=$(terraform -chdir=terraform output -raw rtsp_server_public_ip)

python services/producer/producer.py \
  --rtsp-url rtsp://${RTSP_IP}:8554/stream \
  --kafka-bootstrap ${KAFKA_BOOTSTRAP}
```

---

## 🧪 Test Commands

```bash
# Health check
curl http://localhost:8000/health

# Test inference API directly
./scripts/local-test.sh test-inference

# View service status with stats
./scripts/local-test.sh status

# View logs
./scripts/local-test.sh logs consumer
./scripts/local-test.sh logs inference

# List S3 images
./scripts/local-test.sh s3-list

# Download latest processed image
./scripts/local-test.sh s3-download
```

---

## 📁 Key Files

| File | Purpose |
|------|---------|
| `services/producer/producer.py` | Captures RTSP frames → Kafka |
| `services/inference/main.py` | FastAPI + YOLOv8 detection |
| `services/consumer/consumer.py` | Kafka → Inference → S3 |
| `docker-compose.yaml` | Local development stack |
| `scripts/local-test.sh` | Local testing helper |
| `scripts/deploy.sh` | AWS deployment script |

---

## 🔧 Troubleshooting

| Issue | Solution |
|-------|----------|
| Inference slow to start | Normal - YOLO model loads in ~60s |
| RTSP "404 Not Found" | Wait for FFmpeg streamer to initialize (~10s) |
| No detections | Lower `INFERENCE_CONFIDENCE_THRESHOLD=0.3` |
| Kafka connection refused | Wait for Kafka to start (~15s) |
| S3 bucket not found | Ensure LocalStack is healthy |

---

## 📖 Full Documentation

See [README.md](./README.md) for complete documentation.
