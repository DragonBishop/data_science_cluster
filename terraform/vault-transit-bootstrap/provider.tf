# Targets the host Transit Vault (127.0.0.1:8200), which provides
# auto-unseal for the in-cluster Vault at 127.0.0.1:8210.
provider "vault" {
  address      = "https://127.0.0.1:8200"
  ca_cert_file = "/opt/vault/tls/tls.crt"
}

provider "kubernetes" {
  config_path = pathexpand("~/.kube/config")
}
