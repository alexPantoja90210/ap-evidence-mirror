# The account id is never written in this file. It is read at plan time and
# used only to build the distribution ARN the bucket policy is conditioned on,
# so this file can live in a public repository unchanged.
data "aws_caller_identity" "current" {}

# Looked up by name rather than hardcoded, because an id recalled from memory
# is an unverifiable constant. A wrong name fails loudly; a wrong id would
# silently point at a different policy.
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

locals {
  distribution_arn = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${var.distribution_id}"
}

resource "aws_s3_bucket" "site" {
  bucket = var.bucket_name
}

# All four on. This is the control that keeps the origin private, declared
# explicitly rather than inherited from an account default.
resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = var.oac_name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"

  # The console's own wording. Left as it is rather than replaced with the
  # provider's default "Managed by Terraform", which would be a change made
  # for the tool's benefit and not for the system's.
  description = "Created by CloudFront"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_All"
  http_version        = "http2"

  # The console enabled IPv6. The provider default is false, so omitting this
  # would have silently disabled it on a working distribution.
  is_ipv6_enabled = true

  # The console stores the distribution's display name as a tag, not as the
  # `comment` field. Declaring `comment` and omitting the tag would have
  # renamed it in the console while adding a field nobody set.
  tags = {
    Name = var.bucket_name
  }

  origin {
    # The console used the global bucket endpoint, not the regional one. For
    # us-east-1 the two are equivalent. Matching what exists keeps the plan
    # empty; switching to the regional endpoint would redeploy the
    # distribution for no benefit, and would be its own decision.
    domain_name              = aws_s3_bucket.site.bucket_domain_name
    origin_id                = var.origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = var.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# The whole design lives in the condition. The service principal
# cloudfront.amazonaws.com is the same for every AWS customer; without
# AWS:SourceArn, any distribution anywhere could read this bucket.
#
# Two deliberate departures from what the console wrote, and they are the only
# two changes this module applies to the account:
#
#   ArnLike -> StringEquals. Equivalent here, because the ARN carries no
#   wildcard. StringEquals says so in the operator itself, so the policy no
#   longer has to be read carefully to know it is an exact match.
#
#   Version 2008-10-17 -> 2012-10-17, the current policy language.
data "aws_iam_policy_document" "site" {
  policy_id = "PolicyForCloudFrontPrivateContent"

  statement {
    sid     = "AllowCloudFrontServicePrincipal"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    resources = ["${aws_s3_bucket.site.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [local.distribution_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json
}
