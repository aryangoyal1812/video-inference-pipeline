terraform {
  required_version = ">= 1.0"

  # Remote backend for shared state (local + CI/CD)
  backend "s3" {
    bucket         = "video-pipeline-terraform-state-281789400082"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "video-pipeline-terraform-locks"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "video-pipeline"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Kubernetes provider configured to use EKS cluster
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}

# Locals for common configurations
locals {
  name            = "video-pipeline"
  cluster_version = "1.31"  # Updated: 1.28 is deprecated, using latest supported version
  
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Project     = local.name
    Environment = var.environment
  }
}

