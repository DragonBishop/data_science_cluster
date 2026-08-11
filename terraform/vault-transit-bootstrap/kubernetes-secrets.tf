resource "kubernetes_secret" "vault_transit_token" {
  metadata {
    name      = "vault-transit-secret"
    namespace = "vault"
  }
  data = {
    token = vault_token.autounseal.client_token
  }
  type = "Opaque"
}

resource "kubernetes_config_map" "vault_transit_ca" {
  metadata {
    name      = "vault-transit-ca"
    namespace = "vault"
  }
  data = {
    "ca.crt" = file("/opt/vault/tls/tls.crt")
  }
}
