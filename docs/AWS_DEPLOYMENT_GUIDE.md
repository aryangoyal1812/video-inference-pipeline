# AWS Deployment Guide: Video Ingestion & Inference Pipeline

This guide provides a comprehensive walkthrough of the infrastructure, Kubernetes architecture, and step-by-step deployment instructions for taking your locally-tested pipeline to AWS.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Infrastructure Deep Dive](#infrastructure-deep-dive)
3. [Kubernetes Components](#kubernetes-components)
4. [Deployment Plan](#deployment-plan)
5. [Cost Optimization Strategies](#cost-optimization-strategies)
6. [Step-by-Step Deployment](#step-by-step-deployment)
7. [Post-Deployment Verification](#post-deployment-verification)
8. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                    AWS Cloud                                     │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                              VPC (10.0.0.0/16)                          │   │
│  │                                                                          │   │
│  │  ┌──────────────────────┐  ┌──────────────────────────────────────┐    │   │
│  │  │   PUBLIC SUBNETS     │  │         PRIVATE SUBNETS              │    │   │
│  │  │                      │  │                                       │    │   │
│  │  │  ┌────────────────┐  │  │  ┌─────────────────────────────────┐ │    │   │
│  │  │  │  EC2 (RTSP)    │  │  │  │        EKS CLUSTER              │ │    │   │
│  │  │  │  - MediaMTX    │  │  │  │                                 │ │    │   │
│  │  │  │  - FFmpeg      │  │  │  │  ┌─────────┐  ┌─────────────┐  │ │    │   │
│  │  │  │  - Producer    │──┼──┼──│──│ Consumer│──│  Inference  │  │ │    │   │
│  │  │  └────────────────┘  │  │  │  │   Pod   │  │   Service   │  │ │    │   │
│  │  │                      │  │  │  └────┬────┘  └─────────────┘  │ │    │   │
│  │  │  ┌────────────────┐  │  │  │       │                        │ │    │   │
│  │  │  │   NAT Gateway  │  │  │  └───────┼────────────────────────┘ │    │   │
│  │  │  └────────────────┘  │  │          │                          │    │   │
│  │  └──────────────────────┘  │          ▼                          │    │   │
│  │                            │  ┌───────────────┐                   │    │   │
│  │                            │  │   MSK (Kafka) │                   │    │   │
│  │                            │  │   2 Brokers   │                   │    │   │
│  │                            │  └───────────────┘                   │    │   │
│  │                            └──────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐    │
│  │     ECR      │  │     S3       │  │  CloudWatch  │  │       IAM        │    │
│  │  (Images)    │  │  (Outputs)   │  │   (Logs)     │  │   (IRSA Roles)   │    │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **RTSP Server (EC2)** → Streams video via MediaMTX
2. **Producer** → Captures frames from RTSP, publishes to Kafka
3. **MSK (Kafka)** → Message broker for video frames
4. **Consumer (EKS)** → Batches 25 frames, calls Inference Service
5. **Inference Service (EKS)** → Runs YOLOv8 object detection
6. **Consumer** → Draws bounding boxes, uploads to S3

---

## Infrastructure Deep Dive

### 1. VPC Configuration (`vpc.tf`)

| Component | Configuration | Purpose |
|-----------|---------------|---------|
| **CIDR Block** | `10.0.0.0/16` | 65,536 IP addresses |
| **Public Subnets** | 3 (one per AZ) | NAT Gateway, RTSP Server |
| **Private Subnets** | 3 (one per AZ) | EKS nodes, MSK brokers |
| **NAT Gateway** | Single (cost optimization) | Internet access for private subnets |
| **DNS Hostnames** | Enabled | Required for EKS |

**Security Groups:**

| SG Name | Ports | Source | Purpose |
|---------|-------|--------|---------|
| `msk-sg` | 9092, 9094, 2181 | VPC CIDR | Kafka plaintext, TLS, Zookeeper |
| `rtsp-sg` | 22, 8554 | 0.0.0.0/0, VPC | SSH, RTSP streaming |

### 2. MSK (Kafka) Configuration (`msk.tf`)

| Setting | Value | Notes |
|---------|-------|-------|
| **Version** | 3.5.1 | Latest stable |
| **Broker Count** | 2 | Minimum for HA |
| **Instance Type** | `kafka.t3.small` | Cost-effective for dev |
| **Storage** | 100 GB EBS per broker | Auto-expandable |
| **Encryption** | TLS + plaintext | Flexible connectivity |

**Key Kafka Settings:**
```properties
auto.create.topics.enable=true      # Topics created on demand
log.retention.hours=24              # Keep logs 24h (cost savings)
num.partitions=3                    # Default partitions
default.replication.factor=2        # Data redundancy
message.max.bytes=10485760          # 10MB max (for frame batches)
```

### 3. EKS Configuration (`eks.tf`)

| Setting | Value | Notes |
|---------|-------|-------|
| **Cluster Version** | 1.28 | Kubernetes version |
| **Node Instance Type** | `t3.medium` | 2 vCPU, 4GB RAM |
| **Node Group Size** | Min: 1, Desired: 2, Max: 5 | Autoscaling enabled |
| **IRSA** | Enabled | Secure pod IAM access |

**Cluster Addons:**
- `coredns` - DNS resolution
- `kube-proxy` - Network proxy
- `vpc-cni` - AWS VPC networking

**IRSA (IAM Roles for Service Accounts):**

The `consumer-pod` IAM role grants:
- **S3**: PutObject, GetObject, ListBucket on output bucket
- **MSK**: Connect, DescribeCluster, ReadData, DescribeTopic

### 4. EC2 RTSP Server (`ec2.tf`)

| Setting | Value |
|---------|-------|
| **Instance Type** | `t3.micro` (free tier eligible) |
| **AMI** | Amazon Linux 2 |
| **Storage** | 20 GB gp3 encrypted |
| **Public IP** | Yes (for SSH and RTSP access) |

**User Data Script Sets Up:**
1. Docker & Docker Compose installation
2. Sample video download
3. MediaMTX + FFmpeg streaming stack
4. Systemd service for auto-start

### 5. S3 Configuration (`s3.tf`)

| Feature | Configuration |
|---------|---------------|
| **Bucket Naming** | `video-pipeline-output-{account_id}-{region}` |
| **Public Access** | Blocked |
| **Versioning** | Enabled |
| **Encryption** | AES-256 server-side |
| **Lifecycle** | Delete after 7 days |

### 6. ECR Repositories (`ec2.tf`)

Three repositories created:
- `video-pipeline/producer`
- `video-pipeline/inference`
- `video-pipeline/consumer`

Each with:
- Image scanning on push
- Lifecycle policy: Keep last 10 images

---

## Kubernetes Components

### Namespace & ConfigMap

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: video-pipeline
```

```yaml
# configmap.yaml - Key configurations
KAFKA_TOPIC: "video-frames"
KAFKA_GROUP_ID: "frame-consumer-group"
BATCH_SIZE: "25"
INFERENCE_CONFIDENCE_THRESHOLD: "0.5"
```

### Inference Service Deployment

| Aspect | Configuration |
|--------|---------------|
| **Replicas** | 2 (HPA scales 2-10) |
| **Image** | YOLOv8n model with FastAPI |
| **Resources** | Requests: 500m CPU, 1Gi RAM / Limits: 2 CPU, 2Gi RAM |
| **Probes** | Liveness: `/health`, Readiness: `/ready` |
| **Service Type** | ClusterIP (internal only) |

### Consumer Deployment

| Aspect | Configuration |
|--------|---------------|
| **Replicas** | 1 |
| **Service Account** | `consumer-sa` with IRSA annotation |
| **Resources** | Requests: 250m CPU, 512Mi RAM / Limits: 1 CPU, 1Gi RAM |

### Horizontal Pod Autoscaler (HPA)

```yaml
# CPU-based autoscaling
metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

**BONUS: KEDA Kafka Lag Autoscaling:**
```yaml
triggers:
  - type: kafka
    metadata:
      lagThreshold: "100"  # Scale when lag > 100 messages
```

---

## Deployment Plan

### Phase 1: Prerequisites (Day 0)

- [ ] **1.1** Create fresh AWS account
- [ ] **1.2** Install required tools:
  - AWS CLI v2
  - Terraform >= 1.0
  - kubectl
  - Docker
- [ ] **1.3** Configure AWS credentials:
  ```bash
  aws configure
  # Enter: Access Key ID, Secret Access Key, Region (us-east-1)
  ```
- [ ] **1.4** Generate SSH key for RTSP server:
  ```bash
  cd terraform
  ssh-keygen -t rsa -b 4096 -f rtsp-key -N "" -C "rtsp-server"
  ```

### Phase 2: Infrastructure Deployment (Day 1)

- [ ] **2.1** Initialize Terraform
- [ ] **2.2** Review plan
- [ ] **2.3** Apply infrastructure
- [ ] **2.4** Note outputs (MSK brokers, S3 bucket, ECR URLs)

### Phase 3: Image Build & Push (Day 1)

- [ ] **3.1** Login to ECR
- [ ] **3.2** Build all three images
- [ ] **3.3** Push to ECR

### Phase 4: Kubernetes Deployment (Day 1)

- [ ] **4.1** Configure kubectl
- [ ] **4.2** Create namespace and secrets
- [ ] **4.3** Deploy inference service
- [ ] **4.4** Deploy consumer
- [ ] **4.5** Verify pods are running

### Phase 5: Validation (Day 1-2)

- [ ] **5.1** Test inference health endpoint
- [ ] **5.2** Start producer on EC2
- [ ] **5.3** Verify S3 uploads
- [ ] **5.4** Check consumer logs

### Phase 6: Cost Optimization (Post-Validation)

- [ ] **6.1** Scale down deployments
- [ ] **6.2** Stop EC2 instance
- [ ] **6.3** Configure scheduled scaling (optional)

---

## Cost Optimization Strategies

### 💰 Estimated Monthly Costs (Running)

| Service | Configuration | Estimated Cost |
|---------|---------------|----------------|
| **EKS Control Plane** | Fixed | $72/month |
| **EC2 Nodes** | 2x t3.medium | ~$60/month |
| **MSK** | 2x kafka.t3.small | ~$80/month |
| **EC2 RTSP** | 1x t3.micro | ~$8/month |
| **NAT Gateway** | 1x | ~$32/month |
| **Data Transfer** | Variable | ~$10/month |
| **S3** | Minimal | ~$1/month |
| **Total Running** | | **~$263/month** |

### Strategy 1: Scale to Zero (Recommended for Testing)

**Scale down Kubernetes deployments:**

```bash
# Scale inference to 0 replicas
kubectl scale deployment inference-service -n video-pipeline --replicas=0

# Scale consumer to 0 replicas
kubectl scale deployment consumer -n video-pipeline --replicas=0

# Verify
kubectl get deployments -n video-pipeline
```

**Scale back up when needed:**

```bash
kubectl scale deployment inference-service -n video-pipeline --replicas=2
kubectl scale deployment consumer -n video-pipeline --replicas=1
```

### Strategy 2: Stop EC2 Instance

```bash
# Get instance ID
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=video-pipeline-rtsp-server" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

# Stop instance (saves ~$8/month)
aws ec2 stop-instances --instance-ids $INSTANCE_ID

# Start when needed
aws ec2 start-instances --instance-ids $INSTANCE_ID
```

### Strategy 3: Scale Down EKS Node Group

```bash
# Scale node group to 0 (saves ~$60/month)
aws eks update-nodegroup-config \
  --cluster-name video-pipeline-cluster \
  --nodegroup-name video-pipeline-node-group \
  --scaling-config minSize=0,maxSize=5,desiredSize=0

# Scale back up
aws eks update-nodegroup-config \
  --cluster-name video-pipeline-cluster \
  --nodegroup-name video-pipeline-node-group \
  --scaling-config minSize=1,maxSize=5,desiredSize=2
```

### Strategy 4: Use Spot Instances (Production)

Update `terraform/eks.tf`:

```hcl
eks_managed_node_groups = {
  spot = {
    instance_types = ["t3.medium", "t3a.medium"]
    capacity_type  = "SPOT"  # Up to 90% savings
    # ...
  }
}
```

### Strategy 5: Scheduled Scaling with AWS EventBridge

Create a Lambda function to scale down at night:

```python
# scale_down_lambda.py
import boto3

def handler(event, context):
    eks = boto3.client('eks')
    ec2 = boto3.client('ec2')
    
    # Scale node group to 0
    eks.update_nodegroup_config(
        clusterName='video-pipeline-cluster',
        nodegroupName='video-pipeline-node-group',
        scalingConfig={'minSize': 0, 'maxSize': 5, 'desiredSize': 0}
    )
    
    # Stop RTSP instance
    # ... (implement based on tags)
```

### Strategy 6: Hibernate/Pause MSK (Manual)

⚠️ **Note:** MSK cannot be stopped/paused. Options:
1. **Keep running** (always-on cost ~$80/month)
2. **Destroy and recreate** via Terraform (takes ~30 minutes)
3. **Use Amazon MSK Serverless** (pay per usage)

### 📊 Cost When Idle (Scaled Down)

| Service | Status | Monthly Cost |
|---------|--------|--------------|
| EKS Control Plane | Running | $72 |
| EC2 Nodes | Scaled to 0 | $0 |
| MSK | Running | $80 |
| EC2 RTSP | Stopped | $0 |
| NAT Gateway | Running | $32 |
| **Total Idle** | | **~$184/month** |

### 🎯 Minimum Cost Strategy

To minimize costs when not actively testing:

1. **Scale EKS nodes to 0** → Saves $60/month
2. **Stop RTSP EC2** → Saves $8/month
3. Keep MSK running (required for pipeline)
4. EKS control plane must stay running

**Absolute minimum:** ~$184/month (EKS control plane + MSK + NAT Gateway)

---

## Step-by-Step Deployment

### Step 1: Deploy Infrastructure

```bash
cd terraform

# Initialize
terraform init

# Review what will be created
terraform plan

# Deploy (takes ~20-30 minutes for MSK)
terraform apply
```

**Save the outputs:**
```bash
terraform output > ../deployment-outputs.txt
```

### Step 2: Configure kubectl

```bash
# Update kubeconfig
aws eks update-kubeconfig --name video-pipeline-cluster --region us-east-1

# Verify connection
kubectl get nodes
```

### Step 3: Build and Push Images

```bash
# Get ECR registry
ECR_REGISTRY=$(aws ecr describe-repositories \
  --query 'repositories[0].repositoryUri' --output text | cut -d'/' -f1)

# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ECR_REGISTRY

# Build and push each service
for service in producer inference consumer; do
  echo "Building $service..."
  docker build -t $ECR_REGISTRY/video-pipeline/$service:latest services/$service/
  docker push $ECR_REGISTRY/video-pipeline/$service:latest
done
```

### Step 4: Deploy to Kubernetes

```bash
# Get values from Terraform
cd terraform
KAFKA_BOOTSTRAP=$(terraform output -raw msk_bootstrap_brokers)
S3_BUCKET=$(terraform output -raw s3_bucket_name)
CONSUMER_ROLE_ARN=$(terraform output -raw consumer_role_arn)
cd ..

# Create namespace
kubectl apply -f k8s/namespace.yaml

# Create secrets
kubectl create secret generic video-pipeline-secrets \
  --namespace video-pipeline \
  --from-literal=KAFKA_BOOTSTRAP_SERVERS="$KAFKA_BOOTSTRAP" \
  --from-literal=S3_BUCKET="$S3_BUCKET"

# Apply ConfigMap
kubectl apply -f k8s/configmap.yaml

# Update deployment files with actual values
sed -i "s|\${ECR_REGISTRY}|$ECR_REGISTRY|g" k8s/inference/deployment.yaml
sed -i "s|\${ECR_REGISTRY}|$ECR_REGISTRY|g" k8s/consumer/deployment.yaml
sed -i "s|\${CONSUMER_ROLE_ARN}|$CONSUMER_ROLE_ARN|g" k8s/consumer/deployment.yaml

# Deploy
kubectl apply -f k8s/inference/
kubectl apply -f k8s/consumer/

# Wait for rollout
kubectl rollout status deployment/inference-service -n video-pipeline
kubectl rollout status deployment/consumer -n video-pipeline
```

### Step 5: Verify Deployment

```bash
# Check pods
kubectl get pods -n video-pipeline

# Test inference health
kubectl port-forward svc/inference-service 8000:8000 -n video-pipeline &
curl http://localhost:8000/health
pkill -f "port-forward"

# View logs
kubectl logs -f deployment/inference-service -n video-pipeline
kubectl logs -f deployment/consumer -n video-pipeline
```

### Step 6: Start the Producer (Optional)

SSH into the RTSP EC2 instance and run:

```bash
# Get RTSP server IP
RTSP_IP=$(terraform -chdir=terraform output -raw rtsp_server_public_ip)

# SSH into instance
ssh -i terraform/rtsp-key ec2-user@$RTSP_IP

# On the EC2 instance, run producer
docker run -it --rm \
  -e RTSP_URL=rtsp://localhost:8554/stream \
  -e KAFKA_BOOTSTRAP_SERVERS=<MSK_BOOTSTRAP> \
  $ECR_REGISTRY/video-pipeline/producer:latest
```

### Step 7: Scale Down for Cost Savings

```bash
# After testing, scale down to save costs
kubectl scale deployment inference-service -n video-pipeline --replicas=0
kubectl scale deployment consumer -n video-pipeline --replicas=0

# Stop RTSP instance
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=video-pipeline-rtsp-server" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
aws ec2 stop-instances --instance-ids $INSTANCE_ID

# Scale down node group
aws eks update-nodegroup-config \
  --cluster-name video-pipeline-cluster \
  --nodegroup-name video-pipeline-node-group \
  --scaling-config minSize=0,maxSize=5,desiredSize=0
```

---

## Post-Deployment Verification

### Health Checks

```bash
# Inference service
kubectl exec -it deployment/inference-service -n video-pipeline -- curl localhost:8000/health

# Consumer connectivity to Kafka
kubectl logs deployment/consumer -n video-pipeline | grep -i "connected\|kafka"
```

### S3 Bucket Check

```bash
# List annotated images
aws s3 ls s3://$S3_BUCKET/annotated/ --recursive

# Download latest
aws s3 cp s3://$S3_BUCKET/annotated/ ./output/ --recursive
```

### Kafka Topic Check

```bash
# List topics (requires kafka CLI on a node with access)
kubectl run kafka-client --rm -it --image=bitnami/kafka:latest -- \
  kafka-topics.sh --bootstrap-server $KAFKA_BOOTSTRAP --list
```

---

## Troubleshooting

### Pods Not Starting

```bash
# Check events
kubectl describe pod <pod-name> -n video-pipeline

# Common issues:
# - Image pull error: Check ECR login and image tag
# - Resource limits: Check node capacity
# - Probe failures: Check service health endpoints
```

### Consumer Can't Connect to Kafka

```bash
# Verify MSK security group allows traffic from EKS
# Check that bootstrap servers are correct in secret
kubectl get secret video-pipeline-secrets -n video-pipeline -o yaml
```

### No Detections in Output

```bash
# Lower confidence threshold
kubectl set env deployment/inference-service \
  INFERENCE_CONFIDENCE_THRESHOLD=0.3 -n video-pipeline
```

### MSK Creation Timeout

MSK clusters take 15-30 minutes to create. If Terraform times out:
```bash
# Check cluster status
aws kafka list-clusters --query 'ClusterInfoList[].State'

# Re-run terraform apply
terraform apply
```

---

## Quick Reference Commands

```bash
# Scale up pipeline
kubectl scale deployment inference-service -n video-pipeline --replicas=2
kubectl scale deployment consumer -n video-pipeline --replicas=1

# Scale down pipeline  
kubectl scale deployment inference-service -n video-pipeline --replicas=0
kubectl scale deployment consumer -n video-pipeline --replicas=0

# View all resources
kubectl get all -n video-pipeline

# Destroy everything
cd terraform && terraform destroy
```

---

## CI/CD Integration

The repository includes GitHub Actions workflows:

| Workflow | Trigger | Actions |
|----------|---------|---------|
| `terraform.yaml` | Push to `terraform/` | Plan/Apply infrastructure |
| `deploy.yaml` | After build success | Deploy to EKS |

**Setup:**
1. Create IAM role for GitHub OIDC
2. Add `AWS_ROLE_ARN` secret to repository
3. Push to `main` to trigger pipelines

---

## Summary

Your pipeline is now ready for AWS deployment! The key points:

1. **Infrastructure**: Terraform creates VPC, MSK, EKS, S3, EC2 in ~30 minutes
2. **Kubernetes**: 2 deployments (inference + consumer) with autoscaling
3. **Cost Control**: Scale to 0 replicas and stop EC2 when not testing
4. **Minimum Idle Cost**: ~$184/month (EKS control plane + MSK + NAT)
5. **Full Running Cost**: ~$263/month

**Next Steps:**
1. Run `terraform apply`
2. Build and push images
3. Deploy to Kubernetes
4. Validate the pipeline
5. Scale down for cost savings

