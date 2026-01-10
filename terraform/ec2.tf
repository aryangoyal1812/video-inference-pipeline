# Get latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# IAM Role for RTSP Server
resource "aws_iam_role" "rtsp_server" {
  name = "${local.name}-rtsp-server"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.tags
}

# Attach SSM policy for management
resource "aws_iam_role_policy_attachment" "rtsp_ssm" {
  role       = aws_iam_role.rtsp_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile
resource "aws_iam_instance_profile" "rtsp_server" {
  name = "${local.name}-rtsp-server"
  role = aws_iam_role.rtsp_server.name
}

# Key pair for SSH access (optional)
resource "aws_key_pair" "rtsp_server" {
  key_name   = "${local.name}-rtsp-key"
  public_key = file("${path.module}/rtsp-key.pub")

  lifecycle {
    ignore_changes = [public_key]
  }
}

# RTSP Server EC2 Instance
resource "aws_instance" "rtsp_server" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.rtsp_instance_type
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.rtsp.id]
  iam_instance_profile   = aws_iam_instance_profile.rtsp_server.name
  key_name               = aws_key_pair.rtsp_server.key_name

  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # Update system
    yum update -y
    
    # Install Docker and Docker Compose
    amazon-linux-extras install docker -y
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ec2-user
    
    # Install Docker Compose
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose

    # Create directory for video
    mkdir -p /home/ec2-user/videos
    chown ec2-user:ec2-user /home/ec2-user/videos

    # Download sample video (Big Buck Bunny - free test video)
    curl -L -o /home/ec2-user/videos/sample.mp4 \
      "https://sample-videos.com/video321/mp4/720/big_buck_bunny_720p_1mb.mp4" || \
    curl -L -o /home/ec2-user/videos/sample.mp4 \
      "https://www.learningcontainer.com/wp-content/uploads/2020/05/sample-mp4-file.mp4"

    # Create docker-compose.yaml for RTSP streaming
    cat > /home/ec2-user/docker-compose.yaml << 'COMPOSEEOF'
services:
  # MediaMTX RTSP Server (replacement for deprecated aler9/rtsp-simple-server)
  rtsp-server:
    image: bluenviron/mediamtx:latest
    container_name: rtsp-server
    ports:
      - "8554:8554"
    environment:
      - MTX_PROTOCOLS=tcp
    restart: unless-stopped

  # FFmpeg streams video file to RTSP server in a loop
  ffmpeg-streamer:
    image: linuxserver/ffmpeg:latest
    container_name: ffmpeg-streamer
    depends_on:
      - rtsp-server
    volumes:
      - /home/ec2-user/videos/sample.mp4:/media/video.mp4:ro
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        echo "Waiting for RTSP server to start..."
        sleep 10
        echo "Starting video stream loop..."
        while true; do
          ffmpeg -re -stream_loop -1 -i /media/video.mp4 \
            -c:v libx264 -preset ultrafast -tune zerolatency \
            -c:a aac -f rtsp -rtsp_transport tcp \
            rtsp://rtsp-server:8554/stream
          echo "FFmpeg exited, restarting in 2s..."
          sleep 2
        done
    restart: unless-stopped

networks:
  default:
    name: rtsp-network
COMPOSEEOF

    chown ec2-user:ec2-user /home/ec2-user/docker-compose.yaml

    # Create systemd service for RTSP streaming stack
    cat > /etc/systemd/system/rtsp-server.service << 'SERVICEEOF'
[Unit]
Description=RTSP Streaming Server (MediaMTX + FFmpeg)
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
WorkingDirectory=/home/ec2-user
ExecStartPre=-/usr/local/bin/docker-compose down
ExecStart=/usr/local/bin/docker-compose up
ExecStop=/usr/local/bin/docker-compose down

[Install]
WantedBy=multi-user.target
SERVICEEOF

    systemctl daemon-reload
    systemctl enable rtsp-server
    systemctl start rtsp-server

    echo "RTSP server setup complete - streaming at rtsp://<PUBLIC_IP>:8554/stream"
  EOF
  )

  tags = merge(local.tags, {
    Name = "${local.name}-rtsp-server"
  })
}

# ECR Repositories for container images
resource "aws_ecr_repository" "producer" {
  name                 = "${local.name}/producer"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_ecr_repository" "inference" {
  name                 = "${local.name}/inference"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_ecr_repository" "consumer" {
  name                 = "${local.name}/consumer"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# Local map to reference ECR repositories for lifecycle policies
locals {
  ecr_repositories = {
    producer  = aws_ecr_repository.producer
    inference = aws_ecr_repository.inference
    consumer  = aws_ecr_repository.consumer
  }
}

# Lifecycle policy for ECR repositories
resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each   = local.ecr_repositories
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus     = "any"
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

