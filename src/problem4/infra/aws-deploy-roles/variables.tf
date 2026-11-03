variable "aws_region" {
  description = "Region of the backend ASG and release bucket."
  type        = string
}

variable "github_repository" {
  description = "owner/repo whose workflows may assume these roles."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "Must be owner/repo."
  }
}

# The OIDC subject is customised (../github-environments) to carry numeric
# IDs, which can never be re-registered, so a deleted-and-recreated repository
# name cannot inherit these roles. Get them with:
#   gh api repos/OWNER/REPO --jq '.owner.id, .id'
variable "github_owner_id" {
  description = "Numeric ID of the repository owner (repository_owner_id claim)."
  type        = number
}

variable "github_repository_id" {
  description = "Numeric ID of the repository (repository_id claim)."
  type        = number
}

variable "stage" {
  description = "staging or production. Selects the GitHub environments (backend-<stage>, frontend-<stage>) trusted by this account's roles."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.stage)
    error_message = "Must be staging or production."
  }
}

variable "create_oidc_provider" {
  description = "Create the account's GitHub OIDC provider. Set false if it already exists (one per account)."
  type        = bool
  default     = true
}

# Backend: owned by the infrastructure stack, referenced here.
variable "release_bucket_name" {
  description = "Bucket holding backend release artifacts under backend/<sha>/."
  type        = string
}

variable "asg_name" {
  description = "Backend Auto Scaling group."
  type        = string
}

variable "launch_template_id" {
  description = "Launch template the backend ASG uses (lt-...)."
  type        = string
}

variable "instance_role_arn" {
  description = "IAM role in the backend instance profile; passed to EC2 when the ASG launches from a new template version."
  type        = string
}

# Frontend
variable "site_bucket_name" {
  description = "Bucket behind CloudFront (origin path /site)."
  type        = string
}

variable "cloudfront_distribution_id" {
  description = "Distribution serving the SPA."
  type        = string
}
