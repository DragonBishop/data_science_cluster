locals {
  ca_permitted_dns_domains = [
    "localhost",
    "seaweedfs-s3", "seaweedfs-s3.seaweedfs", "seaweedfs-s3.seaweedfs.svc",
    "seaweedfs-s3.seaweedfs.svc.cluster.local",
    "kube-prometheus-stack-operator", "kube-prometheus-stack-operator.observability.svc",
    "internal", "cilium.io", "cluster.local", "hubble-relay",
  ]
  leaf_pki_domains = [
    var.internal_domain,
    "svc.cluster.local",
    "hubble-grpc.cilium.io", "hubble-relay.cilium.io", "hubble-metrics.cilium.io", "hubble-ui.cilium.io",
    "seaweedfs-s3", "seaweedfs-s3.seaweedfs", "seaweedfs-s3.seaweedfs.svc",
    "kube-prometheus-stack-operator", "kube-prometheus-stack-operator.observability.svc",
    "localhost",
  ]
}

resource "vault_mount" "pki_root" {
  path                  = "pki"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000 #10y
}

resource "vault_pki_secret_backend_root_cert" "root" {
  backend     = vault_mount.pki_root.path
  type        = "internal"
  common_name = "data-science-cluster Root CA"
  ttl         = "315360000"
  key_type    = "ec"
  key_bits    = 256
  issuer_name = "root"

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_mount" "pki_int" {
  path                  = "pki_int"
  type                  = "pki"
  max_lease_ttl_seconds = 63072000 # 2y
}

resource "vault_pki_secret_backend_intermediate_cert_request" "int" {
  backend     = vault_mount.pki_int.path
  type        = "internal"
  common_name = "data-science-cluster Intermediate CA"
  key_type    = "ec"
  key_bits    = 256
}

resource "vault_pki_secret_backend_root_sign_intermediate" "int_signed" {
  backend               = vault_mount.pki_root.path
  csr                   = vault_pki_secret_backend_intermediate_cert_request.int.csr
  common_name           = "data-science-cluster Intermediate CA"
  ttl                   = "63072000"
  permitted_dns_domains = local.ca_permitted_dns_domains
}

resource "vault_pki_secret_backend_intermediate_set_signed" "int" {
  backend     = vault_mount.pki_int.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.int_signed.certificate_bundle
}

resource "vault_pki_secret_backend_role" "internal_server" {
  backend            = vault_mount.pki_int.path
  name               = "internal-server"
  allowed_domains    = local.leaf_pki_domains
  allow_bare_domains = true
  allow_subdomains   = true
  allow_glob_domains = false
  allow_ip_sans      = false
  server_flag        = true
  client_flag        = true
  require_cn         = false
  key_type           = "any"
  ttl                = 2592000
  max_ttl            = 2592000
  no_store           = true # cert-manager stores the certificates
}

# Desktop CA for the internal domain and localhost
locals {
  desktop_pki_domains = [var.internal_domain, "localhost"]
}

resource "vault_mount" "pki_desktop" {
  path                  = "pki_desktop"
  type                  = "pki"
  max_lease_ttl_seconds = 63072000 # 2y
}

resource "vault_pki_secret_backend_intermediate_cert_request" "desktop" {
  backend     = vault_mount.pki_desktop.path
  type        = "internal"
  common_name = "data-science-cluster Desktop CA"
  key_type    = "ec"
  key_bits    = 256
}

resource "vault_pki_secret_backend_root_sign_intermediate" "desktop" {
  backend               = vault_mount.pki_root.path
  csr                   = vault_pki_secret_backend_intermediate_cert_request.desktop.csr
  common_name           = "data-science-cluster Desktop CA"
  ttl                   = "63072000"
  permitted_dns_domains = local.desktop_pki_domains
}

resource "vault_pki_secret_backend_intermediate_set_signed" "desktop" {
  backend     = vault_mount.pki_desktop.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.desktop.certificate_bundle
}

resource "vault_pki_secret_backend_role" "desktop" {
  backend                     = vault_mount.pki_desktop.path
  name                        = "desktop"
  allowed_domains             = local.desktop_pki_domains
  allow_bare_domains          = true
  allow_subdomains            = true
  allow_glob_domains          = false
  allow_wildcard_certificates = true
  allow_ip_sans               = false
  server_flag                 = true
  client_flag                 = false
  require_cn                  = false
  key_type                    = "any"
  ttl                         = 2592000
  max_ttl                     = 2592000
  no_store                    = true # cert-manager stores the certificates
}

# The desktop intermediate for the workstation's trust store
output "desktop_ca" {
  value = vault_pki_secret_backend_root_sign_intermediate.desktop.certificate
}
