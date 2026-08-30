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
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "postgis-role"
  bound_service_account_names      = ["postgis-vault-auth"]
  bound_service_account_namespaces = ["databases"]
  token_policies                   = [vault_policy.postgis.name]
  token_ttl                        = 86400 # 24h
}

resource "vault_policy" "cert_manager_pki" {
  name   = "cert-manager-pki-policy"
  policy = <<EOT
path "pki_int/sign/internal-server" { capabilities = ["update"] }
EOT
}

resource "vault_kubernetes_auth_backend_role" "cert_manager" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "cert-manager-pki-role"
  bound_service_account_names      = ["cert-manager"]
  bound_service_account_namespaces = ["cert-manager"]
  token_policies                   = [vault_policy.cert_manager_pki.name]
  token_ttl                        = 3600 # 1h
}