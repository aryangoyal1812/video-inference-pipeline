#!/bin/bash
# AWS Resource Management Script for Video Pipeline
# Use this to easily scale up/down resources and manage costs

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="video-pipeline-cluster"
NAMESPACE="video-pipeline"

# Get the node group name dynamically (handles name with timestamp suffix)
get_node_group_name() {
    aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $AWS_REGION \
        --query 'nodegroups[0]' --output text 2>/dev/null || echo "vp-nodes"
}

NODE_GROUP_NAME=$(get_node_group_name)

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

get_rtsp_instance_id() {
    aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=video-pipeline-rtsp-server" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text --region $AWS_REGION 2>/dev/null || echo ""
}

get_rtsp_instance_state() {
    aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=video-pipeline-rtsp-server" \
        --query 'Reservations[].Instances[].State.Name' \
        --output text --region $AWS_REGION 2>/dev/null || echo "unknown"
}

# ============================================
# STATUS COMMANDS
# ============================================

show_status() {
    log_section "AWS Resource Status"
    
    # Check kubectl connection
    echo "📦 Kubernetes Cluster:"
    if kubectl cluster-info &>/dev/null; then
        echo -e "   ${GREEN}✓${NC} Connected to EKS cluster"
        
        # Get node info
        NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        echo "   Nodes: $NODE_COUNT"
        
        # Get deployments
        echo -e "\n📋 Deployments:"
        kubectl get deployments -n $NAMESPACE 2>/dev/null | sed 's/^/   /' || echo "   No deployments found"
        
        # Get pods
        echo -e "\n🔹 Pods:"
        kubectl get pods -n $NAMESPACE 2>/dev/null | sed 's/^/   /' || echo "   No pods found"
    else
        echo -e "   ${RED}✗${NC} Not connected to cluster"
        echo "   Run: aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION"
    fi
    
    # Check EC2 RTSP Server
    echo -e "\n🖥️  EC2 RTSP Server:"
    INSTANCE_ID=$(get_rtsp_instance_id)
    if [ -n "$INSTANCE_ID" ]; then
        STATE=$(get_rtsp_instance_state)
        case $STATE in
            running)
                echo -e "   ${GREEN}●${NC} Running (Instance: $INSTANCE_ID)"
                IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
                    --query 'Reservations[].Instances[].PublicIpAddress' --output text --region $AWS_REGION)
                echo "   Public IP: $IP"
                ;;
            stopped)
                echo -e "   ${YELLOW}●${NC} Stopped (Instance: $INSTANCE_ID)"
                ;;
            *)
                echo -e "   ${RED}●${NC} State: $STATE (Instance: $INSTANCE_ID)"
                ;;
        esac
    else
        echo "   Not found"
    fi
    
    # Check MSK
    echo -e "\n📨 MSK (Kafka):"
    MSK_CLUSTER=$(aws kafka list-clusters --query 'ClusterInfoList[?ClusterName==`video-pipeline-kafka`]' \
        --output json --region $AWS_REGION 2>/dev/null)
    if [ -n "$MSK_CLUSTER" ] && [ "$MSK_CLUSTER" != "[]" ]; then
        MSK_STATE=$(echo $MSK_CLUSTER | jq -r '.[0].State')
        echo -e "   ${GREEN}●${NC} $MSK_STATE"
    else
        echo "   Not found"
    fi
    
    # Estimate costs
    echo -e "\n💰 Estimated Running Costs:"
    echo "   EKS Control Plane:  \$72/month (always on)"
    echo "   MSK Cluster:        \$80/month (always on)"
    echo "   NAT Gateway:        \$32/month (always on)"
    if [ "$STATE" = "running" ]; then
        echo "   EC2 RTSP:           ~\$8/month"
    else
        echo "   EC2 RTSP:           \$0 (stopped)"
    fi
    if [ "$NODE_COUNT" -gt 0 ] 2>/dev/null; then
        echo "   EKS Nodes:          ~\$15/node/month (t3.small)"
    else
        echo "   EKS Nodes:          \$0 (scaled down)"
    fi
}

# ============================================
# SCALE UP COMMANDS
# ============================================

scale_up_all() {
    log_section "Scaling Up All Resources"
    
    scale_up_nodes
    scale_up_deployments
    start_rtsp
    
    log_info "All resources scaled up!"
    show_status
}

scale_up_nodes() {
    log_info "Scaling up EKS node group..."
    
    aws eks update-nodegroup-config \
        --cluster-name $CLUSTER_NAME \
        --nodegroup-name $NODE_GROUP_NAME \
        --scaling-config minSize=1,maxSize=5,desiredSize=1 \
        --region $AWS_REGION
    
    log_info "Node group scaling initiated. Waiting for nodes..."
    
    # Wait for nodes to be ready (up to 5 minutes)
    for i in {1..30}; do
        READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
        if [ "$READY_NODES" -ge 1 ]; then
            log_info "Nodes ready: $READY_NODES"
            break
        fi
        echo "   Waiting for nodes... ($i/30)"
        sleep 10
    done
}

scale_up_deployments() {
    log_info "Scaling up Kubernetes deployments..."
    
    # Update kubeconfig first
    aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION &>/dev/null
    
    # Using 1 replica for t3.small nodes (limited memory)
    kubectl scale deployment inference-service -n $NAMESPACE --replicas=1 2>/dev/null || true
    kubectl scale deployment consumer -n $NAMESPACE --replicas=1 2>/dev/null || true
    
    log_info "Deployments scaled up (1 replica each for t3.small)"
}

start_rtsp() {
    log_info "Starting RTSP EC2 instance..."
    
    INSTANCE_ID=$(get_rtsp_instance_id)
    if [ -n "$INSTANCE_ID" ]; then
        STATE=$(get_rtsp_instance_state)
        if [ "$STATE" = "stopped" ]; then
            aws ec2 start-instances --instance-ids $INSTANCE_ID --region $AWS_REGION
            log_info "RTSP instance starting..."
            
            # Wait for running state
            aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $AWS_REGION
            
            IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
                --query 'Reservations[].Instances[].PublicIpAddress' --output text --region $AWS_REGION)
            log_info "RTSP instance running at: $IP"
            
            # Wait for SSM agent to be ready
            log_info "Waiting for SSM agent..."
            sleep 30
            
            # Start RTSP containers
            start_rtsp_containers
        else
            log_warn "RTSP instance already in state: $STATE"
        fi
    else
        log_error "RTSP instance not found"
    fi
}

start_rtsp_containers() {
    log_info "Starting RTSP containers (MediaMTX + FFmpeg)..."
    
    INSTANCE_ID=$(get_rtsp_instance_id)
    if [ -z "$INSTANCE_ID" ]; then
        log_error "RTSP instance not found"
        return 1
    fi
    
    STATE=$(get_rtsp_instance_state)
    if [ "$STATE" != "running" ]; then
        log_error "RTSP instance is not running (state: $STATE)"
        return 1
    fi
    
    # Start MediaMTX and FFmpeg via SSM
    COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=[
            "docker start mediamtx 2>/dev/null || docker run -d --name mediamtx --network host bluenviron/mediamtx:latest",
            "sleep 3",
            "docker start ffmpeg-streamer 2>/dev/null || docker run -d --name ffmpeg-streamer --network host -v /home/ec2-user/video:/media linuxserver/ffmpeg -re -stream_loop -1 -i /media/video.mp4 -c copy -f rtsp rtsp://localhost:8554/stream",
            "sleep 2",
            "docker ps --format \"table {{.Names}}\t{{.Status}}\""
        ]' \
        --region $AWS_REGION \
        --output text \
        --query 'Command.CommandId')
    
    log_info "Waiting for containers to start..."
    sleep 10
    
    # Get command output
    aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --region $AWS_REGION \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null || log_warn "Could not get command output"
    
    log_info "RTSP containers started"
}

start_producer() {
    log_info "Starting producer container on EC2..."
    
    INSTANCE_ID=$(get_rtsp_instance_id)
    if [ -z "$INSTANCE_ID" ]; then
        log_error "RTSP instance not found"
        return 1
    fi
    
    STATE=$(get_rtsp_instance_state)
    if [ "$STATE" != "running" ]; then
        log_error "RTSP instance is not running (state: $STATE)"
        return 1
    fi
    
    # Get ECR registry
    ECR_REGISTRY="281789400082.dkr.ecr.${AWS_REGION}.amazonaws.com"
    
    # Start producer via SSM
    COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[
            'docker rm -f producer 2>/dev/null || true',
            'aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY}',
            'KAFKA_BOOTSTRAP=\$(aws kafka get-bootstrap-brokers --cluster-arn \$(aws kafka list-clusters --region ${AWS_REGION} --query ClusterInfoList[0].ClusterArn --output text) --region ${AWS_REGION} --query BootstrapBrokerString --output text)',
            'echo \"Kafka bootstrap: \$KAFKA_BOOTSTRAP\"',
            'docker run -d --name producer --network host -e KAFKA_BOOTSTRAP_SERVERS=\$KAFKA_BOOTSTRAP -e RTSP_URL=rtsp://localhost:8554/stream ${ECR_REGISTRY}/video-pipeline/producer:latest',
            'sleep 3',
            'docker ps --format \"table {{.Names}}\t{{.Status}}\" | grep -E \"NAMES|producer\"'
        ]" \
        --region $AWS_REGION \
        --output text \
        --query 'Command.CommandId')
    
    log_info "Waiting for producer to start..."
    sleep 15
    
    # Get command output
    OUTPUT=$(aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --region $AWS_REGION \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null)
    
    echo "$OUTPUT"
    log_info "Producer container started"
}

stop_producer() {
    log_info "Stopping producer container..."
    
    INSTANCE_ID=$(get_rtsp_instance_id)
    if [ -z "$INSTANCE_ID" ]; then
        log_error "RTSP instance not found"
        return 1
    fi
    
    aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["docker stop producer && docker rm producer"]' \
        --region $AWS_REGION \
        --output text > /dev/null
    
    log_info "Producer stopped"
}

# ============================================
# SCALE DOWN COMMANDS
# ============================================

scale_down_all() {
    log_section "Scaling Down All Resources (Cost Saving Mode)"
    
    scale_down_deployments
    scale_down_nodes
    stop_rtsp
    
    log_info "All resources scaled down!"
    echo -e "\n${GREEN}💰 Estimated monthly cost in this state: ~\$184${NC}"
    echo "   (EKS control plane + MSK + NAT Gateway)"
}

scale_down_deployments() {
    log_info "Scaling down Kubernetes deployments..."
    
    # Update kubeconfig first
    aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION &>/dev/null
    
    kubectl scale deployment inference-service -n $NAMESPACE --replicas=0 2>/dev/null || true
    kubectl scale deployment consumer -n $NAMESPACE --replicas=0 2>/dev/null || true
    
    log_info "Deployments scaled to 0 replicas"
}

scale_down_nodes() {
    log_info "Scaling down EKS node group to 0..."
    
    aws eks update-nodegroup-config \
        --cluster-name $CLUSTER_NAME \
        --nodegroup-name $NODE_GROUP_NAME \
        --scaling-config minSize=0,maxSize=5,desiredSize=0 \
        --region $AWS_REGION
    
    log_info "Node group scaling down (this may take a few minutes)"
}

stop_rtsp() {
    log_info "Stopping RTSP EC2 instance..."
    
    INSTANCE_ID=$(get_rtsp_instance_id)
    if [ -n "$INSTANCE_ID" ]; then
        STATE=$(get_rtsp_instance_state)
        if [ "$STATE" = "running" ]; then
            aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $AWS_REGION
            log_info "RTSP instance stopping..."
        else
            log_warn "RTSP instance already in state: $STATE"
        fi
    else
        log_error "RTSP instance not found"
    fi
}

# ============================================
# BUILD AND PUSH IMAGES
# ============================================

build_and_push() {
    log_section "Building and Pushing Docker Images"
    
    # Get ECR registry
    ECR_REGISTRY=$(aws ecr describe-repositories --query 'repositories[0].repositoryUri' \
        --output text --region $AWS_REGION | cut -d'/' -f1)
    
    if [ -z "$ECR_REGISTRY" ]; then
        log_error "No ECR repositories found. Run terraform apply first."
        exit 1
    fi
    
    log_info "ECR Registry: $ECR_REGISTRY"
    
    # Login to ECR
    log_info "Logging into ECR..."
    aws ecr get-login-password --region $AWS_REGION | \
        docker login --username AWS --password-stdin $ECR_REGISTRY
    
    # Build and push each service
    for service in producer inference consumer; do
        log_info "Building $service..."
        docker build -t $ECR_REGISTRY/video-pipeline/$service:latest services/$service/
        
        log_info "Pushing $service..."
        docker push $ECR_REGISTRY/video-pipeline/$service:latest
    done
    
    log_info "All images pushed successfully!"
}

# ============================================
# QUICK TEST COMMANDS
# ============================================

quick_test() {
    log_section "Quick Pipeline Test"
    
    # Update kubeconfig
    aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION &>/dev/null
    
    # Check if pods are running
    INFERENCE_PODS=$(kubectl get pods -n $NAMESPACE -l app=inference-service --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    
    if [ "$INFERENCE_PODS" = "0" ]; then
        log_error "No inference pods running. Run '$0 scale-up' first."
        exit 1
    fi
    
    log_info "Port-forwarding to inference service..."
    kubectl port-forward svc/inference-service 8000:8000 -n $NAMESPACE &
    PF_PID=$!
    sleep 3
    
    log_info "Testing health endpoint..."
    if curl -sf http://localhost:8000/health; then
        echo -e "\n${GREEN}✓ Health check passed!${NC}"
    else
        echo -e "\n${RED}✗ Health check failed${NC}"
    fi
    
    # Cleanup
    kill $PF_PID 2>/dev/null || true
}

# ============================================
# CONNECT COMMANDS
# ============================================

connect_eks() {
    log_info "Configuring kubectl for EKS..."
    aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
    log_info "kubectl configured successfully"
    kubectl get nodes
}

connect_rtsp() {
    INSTANCE_ID=$(get_rtsp_instance_id)
    if [ -n "$INSTANCE_ID" ]; then
        IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
            --query 'Reservations[].Instances[].PublicIpAddress' --output text --region $AWS_REGION)
        
        if [ -n "$IP" ] && [ "$IP" != "None" ]; then
            log_info "Connecting to RTSP server at $IP..."
            echo "Command: ssh -i terraform/rtsp-key ec2-user@$IP"
            ssh -i terraform/rtsp-key ec2-user@$IP
        else
            log_error "Instance not running or no public IP"
        fi
    else
        log_error "RTSP instance not found"
    fi
}

# ============================================
# DESTROY COMMANDS
# ============================================

destroy_all() {
    log_section "⚠️  DESTROY ALL RESOURCES"
    
    echo -e "${RED}This will permanently delete all AWS resources!${NC}"
    echo "Including: EKS cluster, MSK cluster, EC2 instance, S3 bucket, VPC"
    echo ""
    read -p "Are you absolutely sure? Type 'destroy' to confirm: " -r
    
    if [ "$REPLY" = "destroy" ]; then
        log_warn "Destroying all resources..."
        
        # Delete Kubernetes resources first
        kubectl delete namespace $NAMESPACE 2>/dev/null || true
        
        # Run Terraform destroy
        cd terraform
        terraform destroy -auto-approve
        cd ..
        
        log_info "All resources destroyed"
    else
        log_info "Destruction cancelled"
    fi
}

# ============================================
# MAIN
# ============================================

show_help() {
    echo "Video Pipeline AWS Resource Manager"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  status              Show status of all AWS resources"
    echo "  build               Build and push Docker images to ECR"
    echo ""
    echo "  scale-up            Scale up all resources (nodes, deployments, EC2 + containers)"
    echo "  scale-up-nodes      Scale up EKS node group only"
    echo "  scale-up-k8s        Scale up K8s deployments only"
    echo "  start-rtsp          Start RTSP EC2 instance + MediaMTX/FFmpeg containers"
    echo "  start-containers    Start MediaMTX + FFmpeg containers (EC2 must be running)"
    echo "  start-producer      Start producer container on EC2"
    echo "  stop-producer       Stop producer container on EC2"
    echo ""
    echo "  scale-down          Scale down all resources (cost saving mode)"
    echo "  scale-down-nodes    Scale down EKS node group to 0"
    echo "  scale-down-k8s      Scale down K8s deployments to 0"
    echo "  stop-rtsp           Stop RTSP EC2 instance"
    echo ""
    echo "  test                Quick pipeline test (health check)"
    echo "  connect-eks         Configure kubectl for EKS"
    echo "  connect-rtsp        SSH into RTSP EC2 instance"
    echo ""
    echo "  destroy             Destroy all AWS resources (DANGEROUS!)"
    echo ""
    echo "Cost Saving Tips:"
    echo "  - Run '$0 scale-down' when not testing to save ~\$35/month"
    echo "  - Minimum idle cost: ~\$184/month (EKS control + MSK + NAT)"
    echo "  - Full running cost: ~\$218/month (with 1x t3.small)"
}

main() {
    case "${1:-}" in
        status)
            show_status
            ;;
        build)
            build_and_push
            ;;
        scale-up)
            scale_up_all
            ;;
        scale-up-nodes)
            scale_up_nodes
            ;;
        scale-up-k8s)
            scale_up_deployments
            ;;
        start-rtsp)
            start_rtsp
            ;;
        start-containers)
            start_rtsp_containers
            ;;
        start-producer)
            start_producer
            ;;
        stop-producer)
            stop_producer
            ;;
        scale-down)
            scale_down_all
            ;;
        scale-down-nodes)
            scale_down_nodes
            ;;
        scale-down-k8s)
            scale_down_deployments
            ;;
        stop-rtsp)
            stop_rtsp
            ;;
        test)
            quick_test
            ;;
        connect-eks)
            connect_eks
            ;;
        connect-rtsp)
            connect_rtsp
            ;;
        destroy)
            destroy_all
            ;;
        help|--help|-h|"")
            show_help
            ;;
        *)
            log_error "Unknown command: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"

