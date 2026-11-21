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

ephemeral "random_password" "zot_push" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "zot_push" {
  mount = vault_mount.kv.path
  name  = "zot-push"
  data_json_wo = jsonencode({
    username = "tekton-builder"
    password = ephemeral.random_password.zot_push.result
    htpasswd = "tekton-builder:${ephemeral.random_password.zot_push.bcrypt_hash}"
  })
  data_json_wo_version = 1
}
