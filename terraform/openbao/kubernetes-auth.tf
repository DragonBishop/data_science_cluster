resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "config" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc"
}

resource "vault_policy" "databases" {
  name = "databases-policy"

  policy = <<EOT
path "secret/data/postgres" { capabilities = ["read"] }
path "secret/data/seaweedfs" { capabilities = ["read"] }
path "secret/metadata/postgres" { capabilities = ["read"] }
path "secret/metadata/seaweedfs" { capabilities = ["read"] }
path "database/creds/postgres-app-role" { capabilities = ["read"] }
EOT
}

resource "vault_kubernetes_auth_backend_role" "databases" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "databases-role"
  bound_service_account_names      = ["databases-openbao-auth"]
  bound_service_account_namespaces = ["databases"]
  audience                         = "openbao"
  token_policies                   = [vault_policy.databases.name]
  token_ttl                        = 86400 # 24h
}

resource "vault_policy" "tekton_results" {
  name = "tekton-results-policy"

  policy = <<EOT
path "database/creds/tekton-results-app-role" { capabilities = ["read"] }
EOT
}

resource "vault_kubernetes_auth_backend_role" "tekton_results" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "tekton-results-role"
  bound_service_account_names      = ["tekton-results-openbao-auth"]
  bound_service_account_namespaces = ["tekton-pipelines"]
  audience                         = "openbao"
  token_policies                   = [vault_policy.tekton_results.name]
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
