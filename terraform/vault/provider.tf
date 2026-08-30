variable "vault_address" {
  type        = string
  description = "Vault API address Terraform talks to (typically a local port-forward to vault-0)."
  default     = "https://127.0.0.1:8210"
}

variable "vault_ca_cert_file" {
  type        = string
  description = "Path to the Vault internal CA cert used to verify the Vault TLS connection."
  default     = "~/.vault-certs/vault-internal-ca.crt"
}

provider "vault" {
  address      = var.vault_address
  ca_cert_file = pathexpand(var.vault_ca_cert_file)
}
