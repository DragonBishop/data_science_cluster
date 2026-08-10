provider "vault" {
  address      = "https://127.0.0.1:8210"
  ca_cert_file = pathexpand("~/.vault-certs/vault-internal-ca.crt")
}