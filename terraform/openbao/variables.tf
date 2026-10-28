variable "postgres_superuser_password" {
  type      = string
  sensitive = true
}

variable "secrets_wo_version" {
  type        = number
  description = "Version for write-only secrets (postgres password, S3 keys). Bumps only on rotation."
}
