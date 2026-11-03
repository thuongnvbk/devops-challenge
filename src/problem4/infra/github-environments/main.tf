# The four deployment environments and their protection rules, as code.
# Splitting environments per app gives each app its own AWS role (the OIDC
# subject is repo:<owner>/<repo>:environment:<name>) and its own approvers.

locals {
  environments = {
    backend-staging     = { production = false }
    backend-production  = { production = true }
    frontend-staging    = { production = false }
    frontend-production = { production = true }
  }

  variables = merge([
    for env, vars in var.environment_variables : {
      for name, value in vars : "${env}/${name}" => { environment = env, name = name, value = value }
    }
  ]...)
}

# Customise the OIDC subject so the AWS trust policies can bind each role to
# a workflow file, not only to an environment: by default any workflow that
# declares `environment: backend-production` gets the same sub. Numeric owner
# and repository IDs replace the name-based "repo" claim, so a re-registered
# name cannot inherit the roles. ../aws-deploy-roles builds the exact sub
# values from this list, in this order; change both together.
resource "github_actions_repository_oidc_subject_claim_customization_template" "this" {
  repository         = var.repository
  use_default        = false
  include_claim_keys = ["repository_owner_id", "repository_id", "context", "job_workflow_ref"]
}

resource "github_repository_environment" "this" {
  for_each = local.environments

  repository  = var.repository
  environment = each.key

  # Production: a second person approves every deploy and rollback, and
  # admins cannot skip the gate.
  prevent_self_review = each.value.production
  can_admins_bypass   = !each.value.production

  dynamic "reviewers" {
    for_each = each.value.production ? [1] : []
    content {
      teams = var.production_reviewer_team_ids
    }
  }

  # Only main may deploy to any environment, so a feature branch (or a
  # workflow_dispatch from one) never receives a deploy role's OIDC token.
  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "main_only" {
  for_each = local.environments

  repository     = var.repository
  environment    = github_repository_environment.this[each.key].environment
  branch_pattern = "main"
}

resource "github_actions_environment_variable" "this" {
  for_each = local.variables

  repository    = var.repository
  environment   = github_repository_environment.this[each.value.environment].environment
  variable_name = each.value.name
  value         = each.value.value
}
