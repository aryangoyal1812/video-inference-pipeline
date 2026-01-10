output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "msk_bootstrap_brokers" {
  description = "MSK bootstrap brokers (plaintext)"
  value       = aws_msk_cluster.main.bootstrap_brokers
  sensitive   = true
}

output "msk_bootstrap_brokers_tls" {
  description = "MSK bootstrap brokers (TLS)"
  value       = aws_msk_cluster.main.bootstrap_brokers_tls
  sensitive   = true
}

output "msk_zookeeper_connect" {
  description = "MSK Zookeeper connection string"
  value       = aws_msk_cluster.main.zookeeper_connect_string
  sensitive   = true
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate" {
  description = "EKS cluster certificate authority data"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "s3_bucket_name" {
  description = "S3 bucket name for annotated images"
  value       = aws_s3_bucket.output.id
}

output "s3_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.output.arn
}

output "rtsp_server_public_ip" {
  description = "Public IP of RTSP server EC2 instance"
  value       = aws_instance.rtsp_server.public_ip
}

output "rtsp_server_private_ip" {
  description = "Private IP of RTSP server EC2 instance"
  value       = aws_instance.rtsp_server.private_ip
}

output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value = {
    producer  = aws_ecr_repository.producer.repository_url
    inference = aws_ecr_repository.inference.repository_url
    consumer  = aws_ecr_repository.consumer.repository_url
  }
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

