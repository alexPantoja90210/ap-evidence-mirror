output "distribution_domain_name" {
  description = "Where the mirror is served."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "origin_url" {
  description = "Direct origin URL. Must return 403 to an anonymous request."
  value       = "https://${aws_s3_bucket.site.bucket_regional_domain_name}/index.html"
}
