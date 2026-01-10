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
NODE_GROUP_NAME="vp-nodes"
NAMESPACE="video-pipeline"

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
    if [ "$STATE" = "running" ]; then
        echo "   EC2 RTSP:           ~\$8/month"
    else
        echo "   EC2 RTSP:           \$0 (stopped)"
    fi
    if [ "$NODE_COUNT" -gt 0 ] 2>/dev/null; then
        echo "   EKS Nodes:          ~\$30/node/month"
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
        --scaling-config minSize=1,maxSize=5,desiredSize=2 \
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
    
    kubectl scale deployment inference-service -n $NAMESPACE --replicas=2 2>/dev/null || true
    kubectl scale deployment consumer -n $NAMESPACE --replicas=1 2>/dev/null || true
    
    log_info "Deployments scaled up"
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
        else
            log_warn "RTSP instance already in state: $STATE"
        fi
    else
        log_error "RTSP instance not found"
    fi
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
    echo ""
    echo "  scale-up            Scale up all resources (nodes, deployments, EC2)"
    echo "  scale-up-nodes      Scale up EKS node group only"
    echo "  scale-up-k8s        Scale up K8s deployments only"
    echo "  start-rtsp          Start RTSP EC2 instance"
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
    echo "  - Run '$0 scale-down' when not testing to save ~\$80/month"
    echo "  - Minimum idle cost: ~\$184/month (EKS control + MSK + NAT)"
    echo "  - Full running cost: ~\$263/month"
}

main() {
    case "${1:-}" in
        status)
            show_status
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

