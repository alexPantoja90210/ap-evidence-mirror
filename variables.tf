variable "region" {
  description = "Region the bucket lives in. CloudFront itself is global."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Existing S3 bucket holding the mirror."
  type        = string
}

variable "distribution_id" {
  description = "Existing CloudFront distribution id."
  type        = string
}

variable "oac_id" {
  description = "Existing Origin Access Control id."
  type        = string
}

variable "oac_name" {
  description = <<-EOT
    Name the console gave the Origin Access Control. Note this is NOT the
    origin id: the two look alike and the console shows them near each other.
    The real value came out of the first terraform plan, not out of reading
    the console.
  EOT
  type        = string
}

variable "origin_id" {
  description = <<-EOT
    Origin id as the console generated it, random suffix and all. Declared
    rather than derived: it is a fact about this account, and reproducing it
    exactly is what keeps the plan empty instead of redeploying the
    distribution for no reason.
  EOT
  type        = string
}
