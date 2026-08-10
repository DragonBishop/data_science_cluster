resource "vault_mount" "kv" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "Static application and superuser credentials"
}

resource "vault_kv_secret_v2" "postgis" {
  mount   = vault_mount.kv.path
  name    = "postgis"
  data_json_wo = jsonencode({
    username = "postgres"
    password = var.postgres_superuser_password
  })
  data_json_wo_version = 1
}

resource "vault_kv_secret_v2" "seaweedfs" {
  mount   = vault_mount.kv.path
  name    = "seaweedfs"
  data_json_wo = jsonencode({
    ACCESS_KEY_ID     = var.s3_access_key
    ACCESS_SECRET_KEY = var.s3_secret_key
    config = jsonencode({
      identities = [{
        name = "cnpg"
        credentials = [{
          accessKey = var.s3_access_key
          secretKey = var.s3_secret_key
        }]
        # Admin only grants bucket create/delete; cnpg-backups already exists
        # (apps/databases/seaweedfs-release.yaml). Write covers DeleteObject,
        # which Barman Cloud's 30d retentionPolicy relies on.
        actions = ["Read", "Write", "List", "Tagging"]
      }]
    })
  })
  data_json_wo_version = 1
}