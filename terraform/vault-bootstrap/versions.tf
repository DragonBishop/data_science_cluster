terraform {
  required_version = ">= 1.11.0"   # write-only arguments need 1.11+
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }
}