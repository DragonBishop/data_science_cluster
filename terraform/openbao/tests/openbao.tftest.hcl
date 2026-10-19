mock_provider "vault" {}

variables {
  state_encryption_passphrase = "foo123"
  openbao_token               = "foo234"
  postgres_superuser_password = "foo345"
  s3_access_key               = "foo456"
  s3_secret_key               = "foo567"
  secrets_wo_version          = "1"
}

run "database_roles_allowed" {
  command = plan

  assert {
    condition = alltrue([
      for role in [
        vault_database_secret_backend_role.postgis_app_role,
        vault_database_secret_backend_role.tekton_results_app_role,
      ] : contains(vault_database_secret_backend_connection.postgis_cluster.allowed_roles, role.name)
    ])
    error_message = "A database role is missing from postgis_cluster's allowed_roles."
  }
}

run "pod_start_ttls" {
  command = plan

  assert {
    condition = alltrue([
      for role in [
        vault_database_secret_backend_role.tekton_results_app_role,
      ] : role.default_ttl == 2764800 && role.max_ttl == 2764800
    ])
    error_message = "A pod-start database role's TTL is not 32 days."
  }
}

run "auth_roles_bound_narrowly" {
  command = plan

  assert {
    condition = alltrue([
      for role in [
        vault_kubernetes_auth_backend_role.postgis,
        vault_kubernetes_auth_backend_role.tekton_results,
        vault_kubernetes_auth_backend_role.cert_manager,
      ] : length(role.bound_service_account_names) == 1 && length(role.bound_service_account_namespaces) == 1
    ])
    error_message = "A Kubernetes auth role is bound to more than one ServiceAccount or namespace."
  }
}

run "policies_read_only" {
  command = plan

  assert {
    condition = alltrue([
      for policy in [
        vault_policy.postgis,
        vault_policy.tekton_results,
      ] : length(regexall("capabilities\\s*=\\s*\\[\"read\"\\]", policy.policy)) == length(regexall("capabilities", policy.policy))
    ])
    error_message = "A policy grants more than read."
  }
}
