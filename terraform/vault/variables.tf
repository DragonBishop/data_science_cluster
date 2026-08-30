
variable "s3_access_key" {
  type      = string
  sensitive = true
}

variable "s3_secret_key" {
  type      = string
  sensitive = true
}

variable "postgres_superuser_password" {
  type        = string
  sensitive   = true
  description = "Postgres superuser password for Vault's database secrets engine connection."
}

variable "secrets_wo_version" {
  type        = number
  description = "Version for write-only secrets (postgres password, S3 keys). Bumps only on rotation."
}
