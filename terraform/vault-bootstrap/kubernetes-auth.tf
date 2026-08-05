resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "config" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc"
}

resource "vault_policy" "postgis" {
  name = "postgis-policy"

  policy = <<EOT
path "secret/data/postgis" { capabilities = ["read"] }
path "secret/data/seaweedfs" { capabilities = ["read"] }
path "secret/metadata/postgis" { capabilities = ["read"] }
path "secret/metadata/seaweedfs" { capabilities = ["read"] }
path "database/creds/postgis-app-role" { capabilities = ["read"] }
EOT
}

resource "vault_kubernetes_auth_backend_role" "postgis" {
  backend                           = vault_auth_backend.kubernetes.path
  role_name                         = "postgis-role"
  bound_service_account_names       = ["postgis-vault-auth"]
  bound_service_account_namespaces  = ["databases"]
  token_policies                    = [vault_policy.postgis.name]
  token_ttl                         = 86400  # 24h, matches the existing role
}