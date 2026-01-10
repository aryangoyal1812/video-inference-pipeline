# S3 Bucket for annotated images
resource "aws_s3_bucket" "output" {
  bucket = "${var.s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = merge(local.tags, {
    Name = "${local.name}-output"
  })
}

# Block public access
resource "aws_s3_bucket_public_access_block" "output" {
  bucket = aws_s3_bucket.output.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning (optional, useful for debugging)
resource "aws_s3_bucket_versioning" "output" {
  bucket = aws_s3_bucket.output.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Lifecycle rules to clean up old annotated images
resource "aws_s3_bucket_lifecycle_configuration" "output" {
  bucket = aws_s3_bucket.output.id

  rule {
    id     = "cleanup-old-images"
    status = "Enabled"

    filter {
      prefix = "annotated/"
    }

    expiration {
      days = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

# Server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "output" {
  bucket = aws_s3_bucket.output.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

