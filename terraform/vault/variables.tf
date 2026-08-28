
variable "s3_access_key" {
  type      = string
  sensitive = true
}

variable "s3_secret_key" {
  type      = string
  sensitive = true
}

variable "postgres_superuser_password" {
  type      = string
  sensitive = true
}

variable "secrets_wo_version" {
  type        = number
  description = "Write-only attribute version for generated app secrets (postgres superuser password, S3 access/secret keys). Bump only when bootstrap-cluster.sh generates a genuinely new set of secrets; unchanged reruns must pass the same value, or Terraform's write-only mechanism will silently skip pushing to Vault."
}