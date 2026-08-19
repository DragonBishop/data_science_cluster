resource "vault_mount" "pki_root" {
    path                    = "pki"
    type                    = "pki"
    max_lease_ttl_seconds   = 315360000 #10y
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
  path                   = "pki_int"
  type                   = "pki"
  max_lease_ttl_seconds  = 63072000 # 2y
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
  permitted_dns_domains = [
    "postgis-cluster-rw", "postgis-cluster-rw.databases", "postgis-cluster-rw.databases.svc",
    "postgis-cluster-rw.databases.svc.cluster.local", "postgis-cluster-ro",
    "postgis-cluster-ro.databases.svc.cluster.local", "postgis-cluster-r",
    "postgis-cluster-r.databases.svc.cluster.local", "localhost", "postgis.internal",
    "seaweedfs-s3", "seaweedfs-s3.databases", "seaweedfs-s3.databases.svc",
    "seaweedfs-s3.databases.svc.cluster.local",
    "internal", "cilium.io", "cluster.local", "hubble-relay", "hubble-ui",
  ]
}

resource "vault_pki_secret_backend_intermediate_set_signed" "int" {
  backend     = vault_mount.pki_int.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.int_signed.certificate_bundle
}

resource "vault_pki_secret_backend_role" "internal_server" {
  backend             = vault_mount.pki_int.path
  name                = "internal-server"
  allowed_domains     = [ 
    "postgis-cluster-rw", "postgis-cluster-rw.databases", "postgis-cluster-rw.databases.svc",
    "postgis-cluster-rw.databases.svc.cluster.local", "postgis-cluster-ro",
    "postgis-cluster-ro.databases.svc.cluster.local", "postgis-cluster-r",
    "postgis-cluster-r.databases.svc.cluster.local", "localhost", "postgis.internal",
    "seaweedfs-s3", "seaweedfs-s3.databases", "seaweedfs-s3.databases.svc",
    "seaweedfs-s3.databases.svc.cluster.local",
    "internal", "cilium.io", "cluster.local", "hubble-relay", "hubble-ui",
   ]
   allow_bare_domains = true
   allow_subdomains   = true
   allow_glob_domains = true
   allow_ip_sans      = true
   server_flag        = true
   client_flag        = true
   require_cn         = false
   key_type           = "any"
   ttl                = 2592000
   max_ttl            = 2592000
   no_store           = true # cert-manager persists issued certs in a Secret.
}

