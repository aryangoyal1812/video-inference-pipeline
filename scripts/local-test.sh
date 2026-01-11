#!/bin/bash
# Local testing script using Docker Compose
# Supports dual-stream video processing with separate S3 buckets
# Usage: ./scripts/local-test.sh [command]

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Dual-stream configuration
KAFKA_TOPIC_1="video-frames-1"
KAFKA_TOPIC_2="video-frames-2"
S3_BUCKET_1="video-pipeline-output-1"
S3_BUCKET_2="video-pipeline-output-2"

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

log_stream() {
    echo -e "${CYAN}[STREAM]${NC} $1"
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
        log_step "Starting Dual-Stream Video Pipeline locally..."
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
        echo -e "${GREEN}🚀 Dual-Stream Pipeline Started Successfully!${NC}"
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        echo -e "${CYAN}Dual-Stream Configuration:${NC}"
        echo "  Topics:  ${KAFKA_TOPIC_1}, ${KAFKA_TOPIC_2}"
        echo "  Buckets: ${S3_BUCKET_1}, ${S3_BUCKET_2}"
        echo ""
        echo -e "${BLUE}Quick Commands:${NC}"
        echo ""
        echo "  1. Check inference health:"
        echo "     curl http://localhost:8000/health"
        echo ""
        echo "  2. Start producer (streams to BOTH topics):"
        echo "     ./scripts/local-test.sh producer"
        echo ""
        echo "  3. View consumer logs:"
        echo "     ./scripts/local-test.sh logs consumer"
        echo ""
        echo "  4. Check annotated images in BOTH S3 buckets:"
        echo "     ./scripts/local-test.sh s3-list"
        echo ""
        echo "  5. Watch Kafka messages (both topics):"
        echo "     ./scripts/local-test.sh kafka-watch"
        echo "     ./scripts/local-test.sh kafka-watch 1   # Topic 1 only"
        echo "     ./scripts/local-test.sh kafka-watch 2   # Topic 2 only"
        echo ""
        echo "  6. Check consumer lag:"
        echo "     ./scripts/local-test.sh kafka-lag"
        echo ""
        echo "  7. Check service status:"
        echo "     ./scripts/local-test.sh status"
        echo ""
        echo "  8. Stop everything:"
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
        log_info "Starting producer (publishing to BOTH topics: ${KAFKA_TOPIC_1}, ${KAFKA_TOPIC_2})..."
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
        log_step "Dual-Stream Pipeline Status"
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
        log_stream "Kafka Topic Statistics (Dual-Stream):"
        
        # Topic 1 stats
        if docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null | grep -q "${KAFKA_TOPIC_1}"; then
            OFFSET1=$(docker exec kafka kafka-run-class kafka.tools.GetOffsetShell --broker-list localhost:9092 --topic "${KAFKA_TOPIC_1}" --time -1 2>/dev/null | cut -d: -f3)
            echo -e "  ${KAFKA_TOPIC_1}: ${BLUE}${OFFSET1:-0} messages${NC}"
        else
            echo -e "  ${KAFKA_TOPIC_1}: ${YELLOW}Not created yet${NC}"
        fi
        
        # Topic 2 stats
        if docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null | grep -q "${KAFKA_TOPIC_2}"; then
            OFFSET2=$(docker exec kafka kafka-run-class kafka.tools.GetOffsetShell --broker-list localhost:9092 --topic "${KAFKA_TOPIC_2}" --time -1 2>/dev/null | cut -d: -f3)
            echo -e "  ${KAFKA_TOPIC_2}: ${BLUE}${OFFSET2:-0} messages${NC}"
        else
            echo -e "  ${KAFKA_TOPIC_2}: ${YELLOW}Not created yet${NC}"
        fi
        
        echo ""
        log_stream "S3 Bucket Statistics (Dual-Stream):"
        
        # Bucket 1 stats
        S3_COUNT_1=$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=http://localhost:4566 s3 ls s3://${S3_BUCKET_1}/annotated/ --recursive 2>/dev/null | wc -l | tr -d ' ')
        echo -e "  ${S3_BUCKET_1}: ${BLUE}${S3_COUNT_1:-0} annotated images${NC}"
        
        # Bucket 2 stats
        S3_COUNT_2=$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=http://localhost:4566 s3 ls s3://${S3_BUCKET_2}/annotated/ --recursive 2>/dev/null | wc -l | tr -d ' ')
        echo -e "  ${S3_BUCKET_2}: ${BLUE}${S3_COUNT_2:-0} annotated images${NC}"
        echo ""
        ;;
    
    s3-list)
        BUCKET="${2:-all}"
        
        if [ "$BUCKET" = "all" ] || [ "$BUCKET" = "1" ]; then
            log_stream "Annotated images in ${S3_BUCKET_1}:"
            AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
                aws --endpoint-url=http://localhost:4566 \
                s3 ls s3://${S3_BUCKET_1}/annotated/ --recursive 2>/dev/null | tail -10 || echo "  (empty)"
            echo ""
            TOTAL1=$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=http://localhost:4566 s3 ls s3://${S3_BUCKET_1}/annotated/ --recursive 2>/dev/null | wc -l | tr -d ' ')
            log_info "Bucket 1 Total: ${TOTAL1:-0} images"
            echo ""
        fi
        
        if [ "$BUCKET" = "all" ] || [ "$BUCKET" = "2" ]; then
            log_stream "Annotated images in ${S3_BUCKET_2}:"
            AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
                aws --endpoint-url=http://localhost:4566 \
                s3 ls s3://${S3_BUCKET_2}/annotated/ --recursive 2>/dev/null | tail -10 || echo "  (empty)"
            echo ""
            TOTAL2=$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url=http://localhost:4566 s3 ls s3://${S3_BUCKET_2}/annotated/ --recursive 2>/dev/null | wc -l | tr -d ' ')
            log_info "Bucket 2 Total: ${TOTAL2:-0} images"
            echo ""
        fi
        ;;
    
    s3-download)
        BUCKET="${2:-1}"
        TARGET_BUCKET="${S3_BUCKET_1}"
        [ "$BUCKET" = "2" ] && TARGET_BUCKET="${S3_BUCKET_2}"
        
        log_info "Downloading latest annotated image from ${TARGET_BUCKET}..."
        mkdir -p output
        
        LATEST=$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
            aws --endpoint-url=http://localhost:4566 \
            s3 ls s3://${TARGET_BUCKET}/annotated/ --recursive 2>/dev/null | tail -1 | awk '{print $4}')
        
        if [ -n "$LATEST" ]; then
            AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
                aws --endpoint-url=http://localhost:4566 \
                s3 cp "s3://${TARGET_BUCKET}/${LATEST}" output/latest_annotated_bucket${BUCKET}.jpg
            log_info "Downloaded to: output/latest_annotated_bucket${BUCKET}.jpg"
            
            # Try to open on macOS
            if command -v open &> /dev/null; then
                open output/latest_annotated_bucket${BUCKET}.jpg 2>/dev/null || true
            fi
        else
            log_warn "No annotated images found in ${TARGET_BUCKET}. Run the producer first."
        fi
        ;;
    
    kafka-stats)
        log_info "Kafka Topic Statistics (Dual-Stream)"
        echo ""
        
        log_stream "Topic: ${KAFKA_TOPIC_1}"
        docker exec kafka kafka-topics --bootstrap-server localhost:9092 --describe --topic ${KAFKA_TOPIC_1} 2>/dev/null || echo "Topic not created yet"
        echo ""
        
        log_stream "Topic: ${KAFKA_TOPIC_2}"
        docker exec kafka kafka-topics --bootstrap-server localhost:9092 --describe --topic ${KAFKA_TOPIC_2} 2>/dev/null || echo "Topic not created yet"
        echo ""
        
        log_info "Message count per partition:"
        echo "  ${KAFKA_TOPIC_1}:"
        docker exec kafka kafka-run-class kafka.tools.GetOffsetShell --broker-list localhost:9092 --topic ${KAFKA_TOPIC_1} --time -1 2>/dev/null || echo "    No messages yet"
        echo "  ${KAFKA_TOPIC_2}:"
        docker exec kafka kafka-run-class kafka.tools.GetOffsetShell --broker-list localhost:9092 --topic ${KAFKA_TOPIC_2} --time -1 2>/dev/null || echo "    No messages yet"
        ;;
    
    kafka-watch)
        TOPIC_NUM="${2:-all}"
        
        if [ "$TOPIC_NUM" = "all" ]; then
            log_info "Watching messages from BOTH topics (Ctrl+C to stop)..."
            log_warn "Note: Messages contain base64 images, so they will be very long"
            echo ""
            # Subscribe to both topics
            docker exec kafka kafka-console-consumer \
                --bootstrap-server localhost:9092 \
                --whitelist "${KAFKA_TOPIC_1}|${KAFKA_TOPIC_2}" \
                --property print.key=true \
                --property print.timestamp=true
        elif [ "$TOPIC_NUM" = "1" ]; then
            log_info "Watching messages from ${KAFKA_TOPIC_1} (Ctrl+C to stop)..."
            docker exec kafka kafka-console-consumer \
                --bootstrap-server localhost:9092 \
                --topic ${KAFKA_TOPIC_1} \
                --property print.key=true \
                --property print.timestamp=true
        elif [ "$TOPIC_NUM" = "2" ]; then
            log_info "Watching messages from ${KAFKA_TOPIC_2} (Ctrl+C to stop)..."
            docker exec kafka kafka-console-consumer \
                --bootstrap-server localhost:9092 \
                --topic ${KAFKA_TOPIC_2} \
                --property print.key=true \
                --property print.timestamp=true
        else
            log_error "Usage: kafka-watch [all|1|2]"
            exit 1
        fi
        ;;
    
    kafka-lag)
        log_info "Kafka Consumer Group Lag (Dual-Stream)"
        echo ""
        docker exec kafka kafka-consumer-groups \
            --bootstrap-server localhost:9092 \
            --group frame-consumer-group \
            --describe 2>/dev/null || echo "Consumer group not found (consumer hasn't started yet)"
        ;;
    
    kafka-messages)
        TOPIC_NUM="${2:-1}"
        COUNT="${3:-5}"
        
        TARGET_TOPIC="${KAFKA_TOPIC_1}"
        [ "$TOPIC_NUM" = "2" ] && TARGET_TOPIC="${KAFKA_TOPIC_2}"
        
        log_info "Reading last ${COUNT} messages from ${TARGET_TOPIC}..."
        echo ""
        docker exec kafka kafka-console-consumer \
            --bootstrap-server localhost:9092 \
            --topic ${TARGET_TOPIC} \
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
        echo -e "${BLUE}Video Pipeline - Local Testing Script (Dual-Stream)${NC}"
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        echo -e "${CYAN}Dual-Stream Configuration:${NC}"
        echo "  Topics:  ${KAFKA_TOPIC_1}, ${KAFKA_TOPIC_2}"
        echo "  Buckets: ${S3_BUCKET_1}, ${S3_BUCKET_2}"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo -e "${GREEN}Core Commands:${NC}"
        echo "  up              Start all services (Kafka, S3, RTSP, Inference, Consumer)"
        echo "  down            Stop all services and clean up volumes"
        echo "  producer        Start the producer (streams to BOTH topics)"
        echo "  status          Show service status, health checks, and dual-stream stats"
        echo ""
        echo -e "${GREEN}Debugging:${NC}"
        echo "  logs [service]  View logs (all or specific: inference, consumer, kafka)"
        echo "  test-inference  Send a test request to the inference API"
        echo ""
        echo -e "${GREEN}Kafka Commands (Dual-Stream):${NC}"
        echo "  kafka-stats         Show both Kafka topic statistics"
        echo "  kafka-watch [1|2]   Watch messages (all, topic 1, or topic 2)"
        echo "  kafka-lag           Show consumer group lag for both topics"
        echo "  kafka-messages 1|2  Read recent messages from topic 1 or 2"
        echo "  kafka-topics        List all Kafka topics"
        echo ""
        echo -e "${GREEN}S3 / Output (Dual-Stream):${NC}"
        echo "  s3-list [1|2]       List annotated images (all, bucket 1, or bucket 2)"
        echo "  s3-download [1|2]   Download latest image from bucket 1 or 2"
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
        echo "  4. Check both buckets:   $0 s3-list"
        echo "  5. Download an image:    $0 s3-download 1"
        echo "  6. Stop everything:      $0 down"
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        exit 0
        ;;
esac
