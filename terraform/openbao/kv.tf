resource "vault_mount" "kv" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "Static application and superuser credentials"
}

ephemeral "random_password" "grafana_admin" {
  length = 32
}

resource "vault_kv_secret_v2" "grafana_admin" {
  mount = vault_mount.kv.path
  name  = "grafana/admin"
  data_json_wo = jsonencode({
    admin-user     = "admin"
    admin-password = ephemeral.random_password.grafana_admin.result
  })
  data_json_wo_version = 1
}
