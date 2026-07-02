output "bucket_ids" {
  value = {
    for k, v in aws_s3_bucket.this : k => v.id
  }
}