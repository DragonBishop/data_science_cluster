
variable "s3_access_key" {
  type      = string
  sensitive = true
}

variable "s3_secret_key" {
  type      = string
  sensitive = true
}

variable "postgres_superuser_password" {
  type      = string
  sensitive = true
}
