provider "vault" {
  address      = "https://127.0.0.1:8200"
  ca_cert_file = "/opt/vault/tls/tls.crt"
}

provider "kubernetes" {
  config_path = pathexpand("~/.kube/config")
}
