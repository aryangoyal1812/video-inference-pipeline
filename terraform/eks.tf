# EKS Cluster using official module
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "${local.name}-cluster"
  cluster_version = local.cluster_version

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # EKS Managed Node Group
  eks_managed_node_groups = {
    general = {
      name = "vp-nodes"  # Short name to avoid IAM role name_prefix length limit (38 chars)

      instance_types = [var.eks_node_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = var.eks_node_min_size
      max_size     = var.eks_node_max_size
      desired_size = var.eks_node_desired_size

      # Disable use_name_prefix to avoid long IAM role names
      iam_role_use_name_prefix = false

      labels = {
        role = "general"
      }

      tags = local.tags
    }
  }

  # Cluster access configuration
  manage_aws_auth_configmap = true

  aws_auth_roles = [
    {
      rolearn  = aws_iam_role.eks_admin.arn
      username = "admin"
      groups   = ["system:masters"]
    },
    {
      rolearn  = "arn:aws:iam::281789400082:role/github-actions-video-pipeline"
      username = "github-actions"
      groups   = ["system:masters"]
    }
  ]

  # Enable IRSA
  enable_irsa = true

  # Cluster addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  tags = local.tags
}

# IAM Role for EKS Admin
resource "aws_iam_role" "eks_admin" {
  name = "${local.name}-eks-admin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
      }
    ]
  })

  tags = local.tags
}

# IAM Role for Consumer Pod (IRSA)
resource "aws_iam_role" "consumer_pod" {
  name = "${local.name}-consumer-pod"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:video-pipeline:consumer-sa"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.tags
}

# IAM Policy for Consumer Pod (S3 and MSK access)
# Grants access to BOTH S3 buckets for dual-stream support
resource "aws_iam_role_policy" "consumer_pod" {
  name = "${local.name}-consumer-policy"
  role = aws_iam_role.consumer_pod.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          # Stream 1 bucket
          aws_s3_bucket.output.arn,
          "${aws_s3_bucket.output.arn}/*",
          # Stream 2 bucket
          aws_s3_bucket.output_2.arn,
          "${aws_s3_bucket.output_2.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup"
        ]
        Resource = [
          aws_msk_cluster.main.arn,
          "${replace(aws_msk_cluster.main.arn, ":cluster/", ":topic/")}/*",
          "${replace(aws_msk_cluster.main.arn, ":cluster/", ":group/")}/*"
        ]
      }
    ]
  })
}

# Output the consumer role ARN for service account annotation
output "consumer_role_arn" {
  description = "IAM Role ARN for consumer service account"
  value       = aws_iam_role.consumer_pod.arn
}

