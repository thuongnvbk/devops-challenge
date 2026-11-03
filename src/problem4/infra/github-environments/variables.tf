variable "github_owner" {
  description = "Organisation that owns the repository."
  type        = string
}

variable "repository" {
  description = "Repository name (without owner)."
  type        = string
}

variable "production_reviewer_team_ids" {
  description = "Teams allowed to approve production deploys and rollbacks."
  type        = list(number)

  validation {
    condition     = length(var.production_reviewer_team_ids) > 0
    error_message = "Production needs at least one reviewer team."
  }
}

variable "environment_variables" {
  description = "Per-environment Actions variables, e.g. AWS_ROLE_ARN from ../aws-deploy-roles, ASG_NAME, SITE_URL. Keys must be the four environment names."
  type        = map(map(string))
}
