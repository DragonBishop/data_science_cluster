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
