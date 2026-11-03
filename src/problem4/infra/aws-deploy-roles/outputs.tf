output "trusted_subjects" {
  description = "Exact OIDC sub values each role accepts; compare with a debug job's token once."
  value       = local.subjects
}

output "role_arns" {
  description = "Set as AWS_ROLE_ARN on the matching GitHub environment (see ../github-environments)."
  value       = { for app, env in local.apps : env => aws_iam_role.deploy[app].arn }
}
