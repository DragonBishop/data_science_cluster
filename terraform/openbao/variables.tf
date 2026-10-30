variable "postgres_superuser_password" {
  type      = string
  sensitive = true
}

variable "secrets_wo_version" {
  type        = number
  description = "Version for write-only secrets (Postgres password, SeaweedFS admin key). Bumps only on rotation."
}

variable "seaweedfs_access_key" {
  type        = string
  sensitive   = true
  description = "Access key of SeaweedFS's static admin identity, the secrets-aws plugin's root credential."
}

variable "seaweedfs_secret_key" {
  type        = string
  sensitive   = true
  description = "Secret key of SeaweedFS's static admin identity."
}

variable "seaweedfs_s3_port" {
  type        = number
  description = "SeaweedFS S3 and IAM port (cluster-config SEAWEEDFS_S3_PORT)."
}

variable "backup_bucket" {
  type        = string
  description = "Bucket Barman's S3 logins are scoped to (cluster-config CNPG_BACKUP_BUCKET)."
}
