# Local copy of the same token, read by the vault-agent-autounseal systemd
# service's token_file auto-auth method. Written to the invoking user's home
# rather than /etc so this module never needs elevated privileges — the
# systemd service runs as root, which can read a user-owned 0600 file
# regardless.
resource "local_sensitive_file" "autounseal_token" {
  content         = vault_token.autounseal.client_token
  filename        = pathexpand("~/.vault-agent/autounseal-token")
  file_permission = "0600"
}
