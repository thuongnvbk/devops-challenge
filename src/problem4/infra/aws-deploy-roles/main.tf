# Deploy roles for ONE environment account. Apply once per account:
#   terraform apply -var-file=staging.tfvars      (staging account)
#   terraform apply -var-file=production.tfvars   (production account)
#
# Each role is assumable only by a job of this repository that (a) runs in the
# matching GitHub environment and (b) is defined by that app's deploy or
# rollback workflow file on main. GitHub enforces the environment's protection
# rules (main only; reviewers for production) before it issues the OIDC token,
# so the trust policy inherits them; (b) stops any other workflow file that
# declares the environment from obtaining the role.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  oidc_host = "token.actions.githubusercontent.com"

  oidc_provider_arn = (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : "arn:${local.partition}:iam::${local.account}:oidc-provider/${local.oidc_host}"
  )

  # app => GitHub environment whose jobs may assume the app's role here
  apps = {
    backend  = "backend-${var.stage}"
    frontend = "frontend-${var.stage}"
  }

  # Workflow files allowed to assume each app's role. For a reusable workflow
  # the job_workflow_ref claim names the called file, so backend.yml's deploy
  # jobs present backend-deploy.yml.
  workflows = {
    backend  = ["backend-deploy.yml", "backend-rollback.yml"]
    frontend = ["frontend-deploy.yml", "frontend-rollback.yml"]
  }

  # OIDC subject under the customisation set in ../github-environments:
  # include_claim_keys = [repository_owner_id, repository_id, context,
  # job_workflow_ref], rendered "key:value" in that order ("context" renders
  # as environment:<name>). Both modules must change together.
  subjects = {
    for app, env in local.apps : app => [
      for wf in local.workflows[app] : join(":", [
        "repository_owner_id", var.github_owner_id,
        "repository_id", var.github_repository_id,
        "environment", env,
        "job_workflow_ref", "${var.github_repository}/.github/workflows/${wf}@refs/heads/main",
      ])
    ]
  }

  launch_template_arn = "arn:${local.partition}:ec2:${var.aws_region}:${local.account}:launch-template/${var.launch_template_id}"
  asg_arn             = "arn:${local.partition}:autoscaling:${var.aws_region}:${local.account}:autoScalingGroup:*:autoScalingGroupName/${var.asg_name}"
  site_bucket_arn     = "arn:${local.partition}:s3:::${var.site_bucket_name}"
}

# AWS trusts GitHub's OIDC endpoint through its own CA store, so no
# thumbprint is pinned here.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  for_each = local.apps

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Exact match, no wildcards: these repository and owner IDs, this
    # environment, one of this app's two workflow files on main. Pull requests
    # and branch jobs carry a different context and can never match. Verify
    # the exact string once with a debug job printing the token's sub claim.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = local.subjects[each.key]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = local.apps

  name                 = "github-${each.key}-deploy-${var.stage}"
  description          = "GitHub Actions ${each.value} deploys for ${var.github_repository}"
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = 3600
}

# --- backend: publish artifact, add launch template version, drive refresh ---

data "aws_iam_policy_document" "backend" {
  statement {
    sid       = "ReleaseArtifacts"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["arn:${local.partition}:s3:::${var.release_bucket_name}/backend/*"]
  }

  # Describe* calls do not support resource-level permissions.
  statement {
    sid = "Describe"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeInstanceRefreshes",
      "ec2:DescribeLaunchTemplateVersions",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AddLaunchTemplateVersion"
    actions   = ["ec2:CreateLaunchTemplateVersion"]
    resources = [local.launch_template_arn]
  }

  # Cancel is used only by recovery to take over a stalled refresh: it stops
  # replacing instances and keeps what is done (never a rollback).
  statement {
    sid = "DriveInstanceRefresh"
    actions = [
      "autoscaling:StartInstanceRefresh",
      "autoscaling:RollbackInstanceRefresh",
      "autoscaling:CancelInstanceRefresh",
    ]
    resources = [local.asg_arn]
  }

  # StartInstanceRefresh dry-runs RunInstances (and PassRole) as the caller
  # to check it may launch from the template. Scoped to this one template.
  statement {
    sid       = "LaunchFromThisTemplateOnly"
    actions   = ["ec2:RunInstances"]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "ec2:LaunchTemplate"
      values   = [local.launch_template_arn]
    }
  }

  statement {
    sid     = "TagOnLaunchOnly"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:${local.partition}:ec2:${var.aws_region}:${local.account}:instance/*",
      "arn:${local.partition}:ec2:${var.aws_region}:${local.account}:volume/*",
      "arn:${local.partition}:ec2:${var.aws_region}:${local.account}:network-interface/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances"]
    }
  }

  statement {
    sid       = "PassInstanceRoleToEc2"
    actions   = ["iam:PassRole"]
    resources = [var.instance_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

# --- frontend: write releases/ and site/, invalidate one distribution --------
# No s3:DeleteObject: a deploy or rollback can never remove a release.

data "aws_iam_policy_document" "frontend" {
  statement {
    sid       = "ListOwnPrefixes"
    actions   = ["s3:ListBucket"]
    resources = [local.site_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["releases/*", "site/*"]
    }
  }

  statement {
    sid       = "ReadWriteReleasesAndSite"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${local.site_bucket_arn}/releases/*", "${local.site_bucket_arn}/site/*"]
  }

  statement {
    sid       = "InvalidateThisDistribution"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = ["arn:${local.partition}:cloudfront::${local.account}:distribution/${var.cloudfront_distribution_id}"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = local.apps

  name   = "deploy"
  role   = aws_iam_role.deploy[each.key].id
  policy = each.key == "backend" ? data.aws_iam_policy_document.backend.json : data.aws_iam_policy_document.frontend.json
}
