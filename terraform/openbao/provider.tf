variable "openbao_address" {
  type        = string
  description = "OpenBao API address Terraform talks to (the openbao-localhost local redirect)."
  default     = "https://127.0.0.1:8210"
}

variable "openbao_ca_cert_file" {
  type        = string
  description = "Path to the OpenBao internal CA cert used to verify the OpenBao TLS connection."
  default     = "../../.local/openbao/certs/openbao-internal-ca.crt"
}

variable "openbao_token" {
  type        = string
  sensitive   = true
  description = "OpenBao token Terraform authenticates with."
}

# hashicorp/vault is API-compatible with OpenBao; no OpenBao provider is released yet.
provider "vault" {
  address      = var.openbao_address
  ca_cert_file = pathexpand(var.openbao_ca_cert_file)
  token        = var.openbao_token
}
