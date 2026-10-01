resource "vault_mount" "transit" {
  path = "transit"
  type = "transit"
}

resource "vault_transit_secret_backend_key" "tekton_chains" {
  backend            = vault_mount.transit.path
  name               = "tekton-chains"
  type               = "ecdsa-p256"
  auto_rotate_period = 2592000 # 30d
  deletion_allowed   = false
}
