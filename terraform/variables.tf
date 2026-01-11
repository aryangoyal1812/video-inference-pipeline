variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "kafka_version" {
  description = "Apache Kafka version for MSK"
  type        = string
  default     = "3.5.1"
}

variable "kafka_instance_type" {
  description = "Instance type for MSK brokers"
  type        = string
  default     = "kafka.t3.small"
}

variable "kafka_broker_count" {
  description = "Number of Kafka brokers"
  type        = number
  default     = 2
}

variable "eks_node_instance_type" {
  description = "Instance type for EKS worker nodes"
  type        = string
  default     = "t3.small"  # Changed from t3.medium due to account restrictions
}

variable "eks_node_min_size" {
  description = "Minimum number of EKS worker nodes"
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Maximum number of EKS worker nodes"
  type        = number
  default     = 5
}

variable "eks_node_desired_size" {
  description = "Desired number of EKS worker nodes"
  type        = number
  default     = 1  # Reduced to 1 to minimize costs
}

variable "rtsp_instance_type" {
  description = "Instance type for RTSP server"
  type        = string
  default     = "t3.micro"
}

variable "s3_bucket_prefix" {
  description = "Prefix for S3 bucket name (stream 1)"
  type        = string
  default     = "video-pipeline-output-1"
}

variable "s3_bucket_prefix_2" {
  description = "Prefix for S3 bucket name (stream 2)"
  type        = string
  default     = "video-pipeline-output-2"
}

variable "kafka_topics" {
  description = "List of Kafka topics for video streams"
  type        = list(string)
  default     = ["video-frames-1", "video-frames-2"]
}

