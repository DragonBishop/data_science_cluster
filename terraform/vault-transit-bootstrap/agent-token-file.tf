resource "local_sensitive_file" "autounseal_token" {
  content         = vault_token.autounseal.client_token
  filename        = pathexpand("~/.vault-agent/autounseal-token")
  file_permission = "0600"
}
