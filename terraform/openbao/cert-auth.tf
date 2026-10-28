resource "vault_auth_backend" "cert" {
  type = "cert"
}

resource "vault_cert_auth_backend_role" "core_test" {
  name             = "core-test"
  backend          = vault_auth_backend.cert.path
  certificate      = vault_pki_secret_backend_root_cert.root.certificate
  allowed_uri_sans = ["spiffe://cluster.internal/ns/tekton-pipelines/sa/core-test"]
  token_policies   = ["default"]
  token_ttl        = 3600 # 1h
}

resource "vault_policy" "rotate_credentials" {
  name   = "rotate-credentials-policy"
  policy = <<EOT
path "database/creds/tekton-results-app-role" { capabilities = ["read"] }
EOT
}

resource "vault_cert_auth_backend_role" "rotate_credentials" {
  name             = "rotate-credentials"
  backend          = vault_auth_backend.cert.path
  certificate      = vault_pki_secret_backend_root_cert.root.certificate
  allowed_uri_sans = ["spiffe://cluster.internal/ns/openbao/sa/rotate-credentials"]
  token_policies   = [vault_policy.rotate_credentials.name]
  token_ttl        = 600 # 10m
}
