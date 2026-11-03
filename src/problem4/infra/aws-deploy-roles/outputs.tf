output "role_arns" {
  description = "Set as AWS_ROLE_ARN on the matching GitHub environment (see ../github-environments)."
  value       = { for app, env in local.apps : env => aws_iam_role.deploy[app].arn }
}
