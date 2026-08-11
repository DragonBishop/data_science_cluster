resource "vault_policy" "autounseal" {
  name = "autounseal-policy"

  policy = <<EOT
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
EOT
}
