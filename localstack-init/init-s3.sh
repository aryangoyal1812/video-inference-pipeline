#!/bin/bash
# Initialize LocalStack S3 bucket for local development

echo "Creating S3 bucket..."
awslocal s3 mb s3://video-pipeline-output

echo "Setting bucket policy..."
awslocal s3api put-bucket-policy --bucket video-pipeline-output --policy '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::video-pipeline-output",
        "arn:aws:s3:::video-pipeline-output/*"
      ]
    }
  ]
}'

echo "S3 bucket created successfully!"

