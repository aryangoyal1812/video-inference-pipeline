#!/bin/bash
# Deployment helper script for Video Pipeline

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="video-pipeline-cluster"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    command -v aws >/dev/null 2>&1 || { log_error "AWS CLI is required but not installed."; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed."; exit 1; }
    command -v terraform >/dev/null 2>&1 || { log_error "Terraform is required but not installed."; exit 1; }
    command -v docker >/dev/null 2>&1 || { log_error "Docker is required but not installed."; exit 1; }
    
    log_info "All prerequisites met!"
}

deploy_infrastructure() {
    log_info "Deploying infrastructure with Terraform..."
    
    cd terraform
    
    # Generate SSH key if not exists
    if [ ! -f rtsp-key.pub ]; then
        log_info "Generating SSH key for RTSP server..."
        ssh-keygen -t rsa -b 4096 -f rtsp-key -N "" -C "rtsp-server"
    fi
    
    terraform init
    terraform plan -out=tfplan
    
    read -p "Apply Terraform plan? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        terraform apply tfplan
    else
        log_warn "Terraform apply cancelled"
        exit 0
    fi
    
    cd ..
}

get_terraform_outputs() {
    log_info "Getting Terraform outputs..."
    
    cd terraform
    
    ECR_REGISTRY=$(terraform output -raw ecr_repository_urls | jq -r '.producer' | cut -d'/' -f1)
    KAFKA_BOOTSTRAP=$(terraform output -raw msk_bootstrap_brokers 2>/dev/null || echo "")
    S3_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "")
    CONSUMER_ROLE_ARN=$(terraform output -raw consumer_role_arn 2>/dev/null || echo "")
    
    cd ..
    
    export ECR_REGISTRY KAFKA_BOOTSTRAP S3_BUCKET CONSUMER_ROLE_ARN
}

build_and_push_images() {
    log_info "Building and pushing Docker images..."
    
    # Login to ECR
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY
    
    # Build and push each service
    for service in producer inference consumer; do
        log_info "Building $service..."
        docker build -t $ECR_REGISTRY/video-pipeline/$service:latest services/$service/
        
        log_info "Pushing $service..."
        docker push $ECR_REGISTRY/video-pipeline/$service:latest
    done
    
    log_info "All images pushed successfully!"
}

configure_kubectl() {
    log_info "Configuring kubectl..."
    aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
}

deploy_kubernetes() {
    log_info "Deploying to Kubernetes..."
    
    # Create namespace
    kubectl apply -f k8s/namespace.yaml
    
    # Create secrets
    kubectl create secret generic video-pipeline-secrets \
        --namespace video-pipeline \
        --from-literal=KAFKA_BOOTSTRAP_SERVERS="$KAFKA_BOOTSTRAP" \
        --from-literal=S3_BUCKET="$S3_BUCKET" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Apply ConfigMap
    kubectl apply -f k8s/configmap.yaml
    
    # Update manifests with actual values
    sed -i.bak "s|\${ECR_REGISTRY}|$ECR_REGISTRY|g" k8s/inference/deployment.yaml
    sed -i.bak "s|\${ECR_REGISTRY}|$ECR_REGISTRY|g" k8s/consumer/deployment.yaml
    sed -i.bak "s|\${CONSUMER_ROLE_ARN}|$CONSUMER_ROLE_ARN|g" k8s/consumer/deployment.yaml
    
    # Deploy services
    kubectl apply -f k8s/inference/
    kubectl apply -f k8s/consumer/
    
    # Restore original files
    mv k8s/inference/deployment.yaml.bak k8s/inference/deployment.yaml
    mv k8s/consumer/deployment.yaml.bak k8s/consumer/deployment.yaml
    
    log_info "Waiting for deployments..."
    kubectl rollout status deployment/inference-service -n video-pipeline --timeout=300s
    kubectl rollout status deployment/consumer -n video-pipeline --timeout=300s
    
    log_info "Kubernetes deployment complete!"
}

show_status() {
    log_info "=== Deployment Status ==="
    
    echo ""
    echo "Deployments:"
    kubectl get deployments -n video-pipeline
    
    echo ""
    echo "Pods:"
    kubectl get pods -n video-pipeline
    
    echo ""
    echo "Services:"
    kubectl get services -n video-pipeline
    
    echo ""
    log_info "=== Quick Start Commands ==="
    echo ""
    echo "# Port forward to inference service:"
    echo "kubectl port-forward svc/inference-service 8000:8000 -n video-pipeline"
    echo ""
    echo "# Check inference health:"
    echo "curl http://localhost:8000/health"
    echo ""
    echo "# View consumer logs:"
    echo "kubectl logs -f deployment/consumer -n video-pipeline"
    echo ""
    echo "# Start producer (on EC2 or locally):"
    echo "python services/producer/producer.py --rtsp-url rtsp://<RTSP_SERVER_IP>:8554/stream --kafka-bootstrap $KAFKA_BOOTSTRAP"
}

main() {
    case "${1:-full}" in
        infra)
            check_prerequisites
            deploy_infrastructure
            ;;
        build)
            check_prerequisites
            get_terraform_outputs
            build_and_push_images
            ;;
        k8s)
            check_prerequisites
            get_terraform_outputs
            configure_kubectl
            deploy_kubernetes
            show_status
            ;;
        status)
            configure_kubectl
            show_status
            ;;
        full)
            check_prerequisites
            deploy_infrastructure
            get_terraform_outputs
            build_and_push_images
            configure_kubectl
            deploy_kubernetes
            show_status
            ;;
        *)
            echo "Usage: $0 {infra|build|k8s|status|full}"
            echo ""
            echo "  infra  - Deploy Terraform infrastructure"
            echo "  build  - Build and push Docker images"
            echo "  k8s    - Deploy to Kubernetes"
            echo "  status - Show deployment status"
            echo "  full   - Full deployment (all steps)"
            exit 1
            ;;
    esac
}

main "$@"

