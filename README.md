# Video Ingestion & Inference Pipeline

A production-ready video processing pipeline that ingests RTSP streams, runs object detection inference on AWS EKS, and stores annotated results in S3.

## Architecture

```
┌─────────────────────────────────┐
│       RTSP Server (EC2)         │
│  ┌───────────┐   ┌───────────┐  │     ┌─────────────────┐     ┌─────────────────┐
│  │ MediaMTX  │◀──│  FFmpeg   │  │────▶│  Frame Producer │────▶│   Kafka (MSK)   │
│  │  (RTSP)   │   │ (Streamer)│  │     │    (Python)     │     │                 │
│  └───────────┘   └───────────┘  │     └─────────────────┘     └────────┬────────┘
└─────────────────────────────────┘                                      │
                                        ┌────────────────────────────────┘
                                        ▼
                  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
                  │    S3 Bucket    │◀────│    Consumer     │────▶│ Inference Svc   │
                  │   (annotated)   │     │ + Post-Process  │◀────│ (FastAPI+YOLO)  │
                  └─────────────────┘     └─────────────────┘     └─────────────────┘
                                               (EKS)                   (EKS)
```

### Data Flow

1. **RTSP Server** (MediaMTX) serves the video stream
2. **FFmpeg Streamer** publishes a looping MP4 video to the RTSP server
3. **Producer** captures frames via OpenCV, publishes to Kafka
4. **Consumer** batches 25 frames, sends to Inference Service
5. **Inference Service** runs YOLOv8 object detection, returns bounding boxes
6. **Consumer** draws boxes on frames, uploads annotated images to S3

### RTSP Streaming Setup

> **Note**: The original `aler9/rtsp-simple-server` image is **deprecated** and has been replaced with `bluenviron/mediamtx`.

The RTSP streaming uses two components:

| Component | Image | Purpose |
|-----------|-------|---------|
| **MediaMTX** | `bluenviron/mediamtx` | RTSP server that accepts video streams and serves them to clients |
| **FFmpeg** | `linuxserver/ffmpeg` | Reads MP4 file, re-encodes, and pushes to MediaMTX in a loop |

This setup is used both locally (Docker Compose) and on AWS (EC2 instance with systemd service).

---

## Project Structure

```
k8/
├── terraform/              # Infrastructure as Code (AWS)
│   ├── main.tf            # Provider configuration
│   ├── variables.tf       # Input variables
│   ├── outputs.tf         # Output values
│   ├── vpc.tf             # VPC, subnets, security groups
│   ├── msk.tf             # MSK (Kafka) cluster
│   ├── eks.tf             # EKS cluster + IRSA roles
│   ├── s3.tf              # S3 bucket for outputs
│   └── ec2.tf             # RTSP server EC2 + ECR repos
│
├── services/
│   ├── producer/          # RTSP → Kafka frame producer
│   │   ├── producer.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   ├── inference/         # FastAPI + YOLOv8 inference API
│   │   ├── main.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   └── consumer/          # Kafka consumer + post-processing
│       ├── consumer.py
│       ├── requirements.txt
│       └── Dockerfile
│
├── k8s/                   # Kubernetes manifests
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── kustomization.yaml
│   ├── inference/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── hpa.yaml       # Autoscaling (CPU + KEDA)
│   └── consumer/
│       └── deployment.yaml
│
├── .github/workflows/     # CI/CD Pipelines
│   ├── build.yaml         # Build & push Docker images
│   ├── deploy.yaml        # Deploy to EKS
│   └── terraform.yaml     # Infrastructure changes
│
├── scripts/
│   ├── deploy.sh          # Full AWS deployment script
│   └── local-test.sh      # Local testing helper
│
├── localstack-init/
│   └── init-s3.sh         # S3 bucket init for local dev
│
├── docker-compose.yaml    # Local development stack
└── README.md
```

---

## Quick Start

### Prerequisites

- Docker & Docker Compose
- Python 3.11+ (optional, for running services directly)
- AWS CLI (for AWS deployment)
- kubectl (for Kubernetes deployment)
- Terraform >= 1.0 (for infrastructure)

---

## 🖥️ Local Development & Testing

### Option 1: Docker Compose (Recommended)

The easiest way to test locally. This starts all services including Kafka, LocalStack (S3 emulation), and the inference pipeline.

```bash
# Start all services
./scripts/local-test.sh up

# Wait ~30 seconds for services to initialize, then verify:
curl http://localhost:8000/health
```

#### Available Commands

```bash
# Start the full stack (Kafka, LocalStack, RTSP, Inference, Consumer)
./scripts/local-test.sh up

# Stop all services and clean up
./scripts/local-test.sh down

# View service status with health checks and stats
./scripts/local-test.sh status

# View logs (all services or specific)
./scripts/local-test.sh logs
./scripts/local-test.sh logs inference
./scripts/local-test.sh logs consumer

# Start the producer to begin streaming video
./scripts/local-test.sh producer

# Test the inference endpoint directly
./scripts/local-test.sh test-inference

# List annotated images in S3
./scripts/local-test.sh s3-list

# Download the latest annotated image
./scripts/local-test.sh s3-download

# Show Kafka topic statistics
./scripts/local-test.sh kafka-stats
```

#### Manual Docker Compose Commands

```bash
# Start services
docker-compose up -d

# Start with producer (streams video immediately)
docker-compose --profile with-producer up -d

# View logs
docker-compose logs -f consumer
docker-compose logs -f inference

# Stop everything
docker-compose down -v
```

### Option 2: Run Services Individually

If you prefer running Python services directly:

```bash
# Create virtual environment
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies for each service
pip install -r services/inference/requirements.txt

# Run inference service
cd services/inference
uvicorn main:app --host 0.0.0.0 --port 8000
```

---

## 🧪 Testing the Pipeline

### 1. Health Check

```bash
curl http://localhost:8000/health
```

Expected response:
```json
{"status": "healthy", "model": "yolov8n.pt", "device": "cpu"}
```

### 2. Test Inference Endpoint

```bash
./scripts/local-test.sh test-inference
```

Or manually with a test image:

```bash
# Create a test payload with a base64-encoded image
python3 << 'EOF'
import base64
import json
import requests
from PIL import Image
import io

# Create test image
img = Image.new('RGB', (640, 480), color='blue')
buffer = io.BytesIO()
img.save(buffer, format='JPEG')
img_b64 = base64.b64encode(buffer.getvalue()).decode()

payload = {
    "stream_id": "test-stream",
    "frames": [{"frame_number": 0, "frame_data": img_b64}]
}

response = requests.post("http://localhost:8000/predict", json=payload)
print(json.dumps(response.json(), indent=2))
EOF
```

### 3. Full Pipeline Test

```bash
# 1. Start the stack
./scripts/local-test.sh up

# 2. Wait for services to be ready (~60s for YOLO model)
sleep 60

# 3. Verify all services are healthy
./scripts/local-test.sh status

# 4. Start the producer to begin video streaming
./scripts/local-test.sh producer

# 5. In another terminal, watch consumer logs
./scripts/local-test.sh logs consumer

# 6. Check S3 bucket for annotated images
./scripts/local-test.sh s3-list

# 7. Download and view a processed image
./scripts/local-test.sh s3-download
```

### 4. View Kafka Topics

```bash
# List topics
docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list

# Watch messages in topic
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic video-frames \
  --from-beginning \
  --max-messages 5
```

### 5. Prometheus Metrics

```bash
curl http://localhost:8000/metrics
```

---

## 🚀 AWS Deployment

### Prerequisites

1. **AWS Account** - Create a fresh AWS account
2. **AWS CLI** - Configure with credentials: `aws configure`
3. **Generate SSH Key** for RTSP server:
   ```bash
   cd terraform
   ssh-keygen -t rsa -b 4096 -f rtsp-key -N "" -C "rtsp-server"
   ```

### Option 1: Automated Deployment

```bash
# Full deployment (Infrastructure + Build + Deploy)
./scripts/deploy.sh full

# Or step-by-step:
./scripts/deploy.sh infra   # Deploy Terraform infrastructure
./scripts/deploy.sh build   # Build and push Docker images
./scripts/deploy.sh k8s     # Deploy to Kubernetes
./scripts/deploy.sh status  # Check deployment status
```

### Option 2: Manual Deployment

#### Step 1: Deploy Infrastructure

```bash
cd terraform

# Initialize Terraform
terraform init

# Preview changes
terraform plan

# Apply (creates VPC, MSK, EKS, S3, EC2, ECR)
terraform apply

# Note the outputs
terraform output
```

#### Step 2: Build and Push Images

```bash
# Get ECR registry URL
ECR_REGISTRY=$(aws ecr describe-repositories --query 'repositories[0].repositoryUri' --output text | cut -d'/' -f1)

# Login to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REGISTRY

# Build and push each service
for service in producer inference consumer; do
  docker build -t $ECR_REGISTRY/video-pipeline/$service:latest services/$service/
  docker push $ECR_REGISTRY/video-pipeline/$service:latest
done
```

#### Step 3: Configure kubectl

```bash
aws eks update-kubeconfig --name video-pipeline-cluster --region us-east-1
```

#### Step 4: Deploy to Kubernetes

```bash
# Create namespace
kubectl apply -f k8s/namespace.yaml

# Create secrets (replace with actual values from Terraform output)
kubectl create secret generic video-pipeline-secrets \
  --namespace video-pipeline \
  --from-literal=KAFKA_BOOTSTRAP_SERVERS="<MSK_BOOTSTRAP>" \
  --from-literal=S3_BUCKET="<S3_BUCKET_NAME>"

# Apply ConfigMap
kubectl apply -f k8s/configmap.yaml

# Deploy services (update image references first)
kubectl apply -f k8s/inference/
kubectl apply -f k8s/consumer/

# Verify deployment
kubectl get pods -n video-pipeline
kubectl get services -n video-pipeline
```

#### Step 5: Start the Producer

SSH into the RTSP EC2 instance or run locally:

```bash
# Get MSK bootstrap servers
KAFKA_BOOTSTRAP=$(terraform -chdir=terraform output -raw msk_bootstrap_brokers)

# Run producer
python services/producer/producer.py \
  --rtsp-url rtsp://<RTSP_SERVER_IP>:8554/stream \
  --kafka-bootstrap $KAFKA_BOOTSTRAP \
  --kafka-topic video-frames
```

---

## 📊 Monitoring & Debugging

### View Kubernetes Logs

```bash
# Inference service logs
kubectl logs -f deployment/inference-service -n video-pipeline

# Consumer logs
kubectl logs -f deployment/consumer -n video-pipeline

# All pods
kubectl get pods -n video-pipeline
kubectl describe pod <pod-name> -n video-pipeline
```

### Port Forward for Local Access

```bash
# Access inference service locally
kubectl port-forward svc/inference-service 8000:8000 -n video-pipeline

# Then test
curl http://localhost:8000/health
```

### Check S3 Bucket

```bash
# List annotated images
aws s3 ls s3://<BUCKET_NAME>/annotated/ --recursive

# Download an image
aws s3 cp s3://<BUCKET_NAME>/annotated/<path>/image.jpg ./
```

### Autoscaling Status

```bash
# Check HPA
kubectl get hpa -n video-pipeline

# Check pod scaling
kubectl get pods -n video-pipeline -w
```

---

## 🔧 Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KAFKA_BOOTSTRAP_SERVERS` | Kafka broker addresses | `localhost:9092` |
| `KAFKA_TOPIC` | Topic for video frames | `video-frames` |
| `KAFKA_GROUP_ID` | Consumer group ID | `frame-consumer-group` |
| `INFERENCE_SERVICE_URL` | Inference API URL | `http://inference-service:8000` |
| `S3_BUCKET` | S3 bucket for outputs | `video-pipeline-output` |
| `S3_PREFIX` | S3 key prefix | `annotated` |
| `AWS_REGION` | AWS region | `us-east-1` |
| `BATCH_SIZE` | Frames per batch | `25` |
| `BATCH_TIMEOUT_SECONDS` | Max wait for batch | `5.0` |
| `INFERENCE_CONFIDENCE_THRESHOLD` | Detection threshold | `0.5` |
| `FRAME_RATE` | Frames per second | `10` |

### Terraform Variables

Edit `terraform/terraform.tfvars` or pass via CLI:

```hcl
aws_region             = "us-east-1"
environment            = "dev"
kafka_instance_type    = "kafka.t3.small"
eks_node_instance_type = "t3.medium"
eks_node_desired_size  = 2
```

---

## 🔄 CI/CD Pipeline

GitHub Actions workflows are provided for:

1. **build.yaml** - Builds and pushes Docker images on code changes
2. **deploy.yaml** - Deploys to EKS after successful build
3. **terraform.yaml** - Plans/applies infrastructure changes

### Setup GitHub Actions

1. Create an IAM role for GitHub OIDC
2. Add secret `AWS_ROLE_ARN` to your repository
3. Push to `main` branch to trigger pipelines

---

## 🧹 Cleanup

### Local

```bash
./scripts/local-test.sh down
docker system prune -a  # Optional: remove all images
```

### AWS

```bash
# Delete Kubernetes resources
kubectl delete namespace video-pipeline

# Destroy infrastructure
cd terraform
terraform destroy
```

---

## 📝 Troubleshooting

### Docker Build Fails with `libgl1-mesa-glx`

This package was renamed in newer Debian. Already fixed in Dockerfiles - use `libgl1` instead.

### RTSP Stream Returns "404 Not Found"

The RTSP stream needs FFmpeg to start publishing to MediaMTX:
- Wait 10-15 seconds after starting services for FFmpeg to initialize
- Check FFmpeg is streaming: `docker logs ffmpeg-streamer`
- Look for "Starting video stream loop..." and frame progress

### Producer Can't Connect to RTSP

- Ensure both `rtsp-server` and `ffmpeg-streamer` containers are running
- Check MediaMTX is receiving the stream: `docker logs rtsp-server`
- Verify with: `docker exec producer python -c "import cv2; print(cv2.VideoCapture('rtsp://rtsp-server:8554/stream').isOpened())"`

### Consumer Can't Connect to Kafka

- Check Kafka is running: `docker-compose ps`
- Verify bootstrap servers: `docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list`

### Inference Service OOM

Increase memory limits in `k8s/inference/deployment.yaml`:

```yaml
resources:
  limits:
    memory: "4Gi"
```

### No Detections in Output

- Lower confidence threshold: Set `INFERENCE_CONFIDENCE_THRESHOLD=0.3`
- Check input video has detectable objects (people, cars, etc.)

### S3 Bucket Not Found

- Ensure LocalStack is healthy: `curl http://localhost:4566/_localstack/health`
- The bucket is created by `localstack-init/init-s3.sh` on startup
- Manually create: `AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=http://localhost:4566 s3 mb s3://video-pipeline-output`

---

## 📚 References

- [YOLOv8 Documentation](https://docs.ultralytics.com/)
- [FastAPI](https://fastapi.tiangolo.com/)
- [Confluent Kafka Python](https://docs.confluent.io/kafka-clients/python/current/overview.html)
- [AWS EKS](https://docs.aws.amazon.com/eks/)
- [AWS MSK](https://docs.aws.amazon.com/msk/)
- [KEDA Kafka Scaler](https://keda.sh/docs/scalers/apache-kafka/)

---

## License

MIT
