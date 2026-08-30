
variable "postgres_superuser_password" {
  type        = string
  sensitive   = true
  description = "Postgres superuser password for Vault's database secrets engine connection."
}

variable "secrets_wo_version" {
  type        = number
  description = "Write-only attribute version for the postgres superuser password. Bump only on a genuine rotation; unchanged runs must pass the same version, or Terraform's write-only mechanism will silently skip pushing to Vault."
}
