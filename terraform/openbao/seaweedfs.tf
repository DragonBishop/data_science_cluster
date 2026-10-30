locals {
  seaweedfs_s3_url = "https://seaweedfs-s3.seaweedfs.svc:${var.seaweedfs_s3_port}"
}

resource "vault_aws_secret_backend" "seaweedfs" {
  path                      = "seaweedfs"
  access_key                = var.seaweedfs_access_key
  secret_key_wo             = var.seaweedfs_secret_key
  secret_key_wo_version     = var.secrets_wo_version
  region                    = "us-east-1"
  iam_endpoint              = local.seaweedfs_s3_url
  sts_endpoint              = local.seaweedfs_s3_url
  default_lease_ttl_seconds = 345600 # 4d
  max_lease_ttl_seconds     = 345600 # 4d
}

resource "vault_aws_secret_backend_role" "barman" {
  backend         = vault_aws_secret_backend.seaweedfs.path
  name            = "barman"
  credential_type = "iam_user"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:*"]
      Resource = ["arn:aws:s3:::${var.backup_bucket}", "arn:aws:s3:::${var.backup_bucket}/*"]
    }]
  })
}
