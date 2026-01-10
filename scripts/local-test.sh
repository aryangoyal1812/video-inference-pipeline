#!/bin/bash
# Local testing script using Docker Compose
# Usage: ./scripts/local-test.sh [command]

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Create test data directory
mkdir -p test-data
mkdir -p localstack-init

# Make init script executable
chmod +x localstack-init/init-s3.sh 2>/dev/null || true

# Download sample video if not exists
if [ ! -f test-data/sample.mp4 ]; then
    log_info "Downloading sample video..."
    curl -L -o test-data/sample.mp4 \
        "https://www.learningcontainer.com/wp-content/uploads/2020/05/sample-mp4-file.mp4" || \
    curl -L -o test-data/sample.mp4 \
        "https://sample-videos.com/video321/mp4/720/big_buck_bunny_720p_1mb.mp4" || \
    log_warn "Could not download sample video. Please place a video file at test-data/sample.mp4"
fi

case "${1:-help}" in
    up)
        log_step "Starting Video Pipeline locally..."
        echo ""
        
        log_info "Starting infrastructure services (Kafka, LocalStack, RTSP)..."
        docker-compose up -d zookeeper kafka localstack rtsp-server
        
        log_info "Waiting for Kafka and LocalStack to initialize..."
        sleep 15
        
        log_info "Starting FFmpeg video streamer..."
        docker-compose up -d ffmpeg-streamer
        
        log_info "Building and starting application services..."
        docker-compose up -d inference consumer
        
        log_info "Waiting for services to be healthy (YOLO model loading takes ~60s)..."
        sleep 30
        
        # Check health
        echo ""
        log_step "Checking service health..."
        if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
            log_info "✅ Inference service is healthy"
        else
            log_warn "⏳ Inference service still starting (this is normal, YOLO model takes ~60s to load)"
        fi
        
        # Check RTSP stream
        if docker logs ffmpeg-streamer 2>&1 | grep -q "Stream #0"; then
            log_info "✅ RTSP video stream is active"
        else
            log_warn "⏳ RTSP stream still initializing..."
        fi
        
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo -e "${GREEN}🚀 Services Started Successfully!${NC}"
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        echo -e "${BLUE}Quick Commands:${NC}"
        echo ""
        echo "  1. Check inference health:"
        echo "     curl http://localhost:8000/health"
        echo ""
        echo "  2. Start producer (begins video processing):"
        echo "     ./scripts/local-test.sh producer"
        echo ""
        echo "  3. Test inference directly:"
        echo "     ./scripts/local-test.sh test-inference"
        echo ""
        echo "  4. View consumer logs:"
        echo "     ./scripts/local-test.sh logs consumer"
        echo ""
        echo "  5. Check annotated images in S3:"
        echo "     ./scripts/local-test.sh s3-list"
        echo ""
        echo "  6. Download a processed image:"
        echo "     ./scripts/local-test.sh s3-download"
        echo ""
        echo "  7. Check service status:"
        echo "     ./scripts/local-test.sh status"
        echo ""
        echo "  8. Watch Kafka messages in real-time:"
        echo "     ./scripts/local-test.sh kafka-watch"
        echo ""
        echo "  9. Check consumer lag:"
        echo "     ./scripts/local-test.sh kafka-lag"
        echo ""
        echo "  10. Stop everything:"
        echo "      ./scripts/local-test.sh down"
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        ;;
    
    down)
        log_info "Stopping services..."
        # Stop producer (which uses a profile) first
        docker-compose --profile with-producer down -v
        # Remove network if still exists
        docker network rm video-pipeline-network 2>/dev/null || true
        log_info "All services stopped and cleaned up"
        ;;
    
    logs)
        docker-compose logs -f "${2:-}"
        ;;
    
    producer)
        log_info "Starting producer..."
        docker-compose --profile with-producer up producer
        ;;
    
    test-inference)
        log_info "Testing inference service..."
        
        # Create a test image
        python3 -c "
import base64
import json
import numpy as np
from PIL import Image
import io

# Create a simple test image
img = Image.new('RGB', (640, 480), color='blue')
buffer = io.BytesIO()
img.save(buffer, format='JPEG')
img_b64 = base64.b64encode(buffer.getvalue()).decode()

payload = {
    'stream_id': 'test-stream',
    'frames': [
        {'frame_number': 0, 'frame_data': img_b64}
    ]
}

print(json.dumps(payload))
" > /tmp/test_payload.json
        
        curl -X POST http://localhost:8000/predict \
            -H "Content-Type: application/json" \
            -d @/tmp/test_payload.json | python3 -m json.tool
        ;;
    
    status)
        log_step "Service Status"
        echo ""
        docker-compose ps
        echo ""
        
        log_info "Checking endpoints..."
        if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
            echo -e "  Inference API:  ${GREEN}✅ http://localhost:8000${NC}"
        else
            echo -e "  Inference API:  ${RED}❌ Not responding${NC}"
        fi
        
        if curl -sf http://localhost:4566/_localstack/health > /dev/null 2>&1; then
            echo -e "  LocalStack S3:  ${GREEN}✅ http://localhost:4566${NC}"
        else
            echo -e "  LocalStack S3:  ${RED}❌ Not responding${NC}"
        fi
        
        if docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list > /dev/null 2>&1; then
            echo -e "  Kafka:          ${GREEN}✅ localhost:9092${NC}"
        else
            echo -e "  Kafka:          ${RED}❌ Not responding${NC}"
        fi
        
        if docker logs ffmpeg-streamer 2>&1 | grep -q "frame=" > /dev/null 2>&1; then
            echo -e "  RTSP Stream:    ${GREEN}✅ rtsp://localhost:8554/stream${NC}"
        else
            echo -e "  RTSP Stream:    ${YELLOW}⏳ Not streaming (start producer to test)${NC}"
        fi
        
        echo ""
        
        # Show Kafka stats
        if docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null | grep -q video-frames; then
            OFFSET=$(docker exec kafka kafka-run-class kafka.tools.GetOffsetShell --broker-list localhost:9092 --topic video-frames --time -1 2>/dev/null | cut -d: -f3)
            echo -e "  Kafka Messages: ${BLUE}${OFFSET:-0} frames in topic${NC}"
        fi
        
        # Show S3 stats
        S3_COUNT=$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=http://localhost:4566 s3 ls s3://video-pipeline-output/annotated/ --recursive 2>/dev/null | wc -l | tr -d ' ')
        echo -e "  S3 Images:      ${BLUE}${S3_COUNT:-0} annotated images${NC}"
        echo ""
        ;;
    
    s3-list)
        log_info "Listing annotated images in S3..."
        AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
            aws --endpoint-url=http://localhost:4566 \
            s3 ls s3://video-pipeline-output/annotated/ --recursive | tail -20
        
        echo ""
        TOTAL=$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=http://localhost:4566 s3 ls s3://video-pipeline-output/annotated/ --recursive 2>/dev/null | wc -l | tr -d ' ')
        log_info "Total: ${TOTAL} images"
        ;;
    
    s3-download)
        log_info "Downloading latest annotated image..."
        mkdir -p output
        
        LATEST=$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
            aws --endpoint-url=http://localhost:4566 \
            s3 ls s3://video-pipeline-output/annotated/ --recursive 2>/dev/null | tail -1 | awk '{print $4}')
        
        if [ -n "$LATEST" ]; then
            AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
                aws --endpoint-url=http://localhost:4566 \
                s3 cp "s3://video-pipeline-output/${LATEST}" output/latest_annotated.jpg
            log_info "Downloaded to: output/latest_annotated.jpg"
            
            # Try to open on macOS
            if command -v open &> /dev/null; then
                open output/latest_annotated.jpg 2>/dev/null || true
            fi
        else
            log_warn "No annotated images found. Run the producer first."
        fi
        ;;
    
    kafka-stats)
        log_info "Kafka Topic Statistics"
        echo ""
        docker exec kafka kafka-topics --bootstrap-server localhost:9092 --describe --topic video-frames 2>/dev/null || echo "Topic not created yet"
        echo ""
        log_info "Message count per partition:"
        docker exec kafka kafka-run-class kafka.tools.GetOffsetShell --broker-list localhost:9092 --topic video-frames --time -1 2>/dev/null || echo "No messages yet"
        ;;
    
    kafka-watch)
        log_info "Watching Kafka messages in real-time (Ctrl+C to stop)..."
        log_warn "Note: Messages contain base64 images, so they will be very long"
        echo ""
        docker exec kafka kafka-console-consumer \
            --bootstrap-server localhost:9092 \
            --topic video-frames \
            --property print.key=true \
            --property print.timestamp=true
        ;;
    
    kafka-lag)
        log_info "Kafka Consumer Group Lag"
        echo ""
        docker exec kafka kafka-consumer-groups \
            --bootstrap-server localhost:9092 \
            --group frame-consumer-group \
            --describe 2>/dev/null || echo "Consumer group not found (consumer hasn't started yet)"
        ;;
    
    kafka-messages)
        COUNT="${2:-5}"
        log_info "Reading last ${COUNT} messages from Kafka..."
        echo ""
        docker exec kafka kafka-console-consumer \
            --bootstrap-server localhost:9092 \
            --topic video-frames \
            --from-beginning \
            --max-messages "${COUNT}" \
            --property print.key=true \
            --property print.timestamp=true 2>/dev/null | head -c 2000
        echo ""
        echo ""
        log_info "(Output truncated - messages contain base64 image data)"
        ;;
    
    kafka-topics)
        log_info "Listing all Kafka topics"
        echo ""
        docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list
        ;;
    
    help|*)
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo -e "${BLUE}Video Pipeline - Local Testing Script${NC}"
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo -e "${GREEN}Core Commands:${NC}"
        echo "  up              Start all services (Kafka, S3, RTSP, Inference, Consumer)"
        echo "  down            Stop all services and clean up volumes"
        echo "  producer        Start the producer to stream video to Kafka"
        echo "  status          Show service status, health checks, and stats"
        echo ""
        echo -e "${GREEN}Debugging:${NC}"
        echo "  logs [service]  View logs (all or specific: inference, consumer, kafka)"
        echo "  test-inference  Send a test request to the inference API"
        echo ""
        echo -e "${GREEN}Kafka Commands:${NC}"
        echo "  kafka-stats     Show Kafka topic statistics"
        echo "  kafka-watch     Watch messages in real-time (Ctrl+C to stop)"
        echo "  kafka-lag       Show consumer group lag (pending messages)"
        echo "  kafka-messages  Read recent messages (usage: kafka-messages [count])"
        echo "  kafka-topics    List all Kafka topics"
        echo ""
        echo -e "${GREEN}S3 / Output:${NC}"
        echo "  s3-list         List annotated images in S3"
        echo "  s3-download     Download the latest annotated image"
        echo ""
        echo -e "${GREEN}Help:${NC}"
        echo "  help            Show this help message"
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo -e "${BLUE}Quick Start:${NC}"
        echo ""
        echo "  1. Start everything:     $0 up"
        echo "  2. Start video stream:   $0 producer"
        echo "  3. Watch processing:     $0 logs consumer"
        echo "  4. Check results:        $0 s3-list"
        echo "  5. Download an image:    $0 s3-download"
        echo "  6. Stop everything:      $0 down"
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        exit 0
        ;;
esac

