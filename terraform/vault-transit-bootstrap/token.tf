resource "vault_mount" "transit" {
  path = "transit"
  type = "transit"
}

resource "vault_transit_secret_backend_key" "autounseal" {
  backend = vault_mount.transit.path
  name    = "autounseal"
}

resource "vault_token" "autounseal" {
  policies          = [vault_policy.autounseal.name]
  no_default_policy = true
  renewable         = true
  period            = "768h"
  no_parent         = true
}
