
variable "state_encryption_passphrase" {
  type        = string
  sensitive   = true
  description = "Passphrase used to derive the key that encrypts this project's Terraform state and plan files at rest."
}

terraform {
  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_encryption_passphrase
    }

    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    state {
      method = method.aes_gcm.main
    }

    plan {
      method = method.aes_gcm.main
    }
  }
}
