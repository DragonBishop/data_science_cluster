mock_provider "vault" {}

variables {
  internal_domain             = "cluster.internal"
  state_encryption_passphrase = "foo123"
  openbao_token               = "foo234"
  postgres_superuser_password = "foo345"
  secrets_wo_version          = "1"
  seaweedfs_access_key        = "foo456"
  seaweedfs_secret_key        = "foo567"
  seaweedfs_s3_port           = 9000
  backup_bucket               = "foo-backups"
}

run "postgres_tls_is_verified" {
  command = plan

  assert {
    condition = (
      strcontains(vault_database_secret_backend_connection.postgres_cluster.postgresql[0].connection_url, "sslmode=verify-full&") &&
      strcontains(vault_database_secret_backend_connection.postgres_cluster.postgresql[0].connection_url, "sslrootcert=/openbao/userconfig/postgres-ca/ca.crt") &&
      !vault_database_secret_backend_connection.postgres_cluster.verify_connection
    )
    error_message = "PostgreSQL must use verified TLS with its mounted CA and defer connection checks until after bootstrap."
  }
}

run "database_roles_allowed" {
  command = plan

  assert {
    condition = alltrue([
      for role in [
        vault_database_secret_backend_role.postgres_app_role,
        vault_database_secret_backend_role.tekton_results_app_role,
      ] : contains(vault_database_secret_backend_connection.postgres_cluster.allowed_roles, role.name)
    ])
    error_message = "A database role is missing from postgres_cluster's allowed_roles."
  }
}

run "pod_start_ttls" {
  command = plan

  assert {
    condition = alltrue([
      for role in [
        vault_database_secret_backend_role.tekton_results_app_role,
      ] : role.default_ttl == 345600 && role.max_ttl == 345600
    ])
    error_message = "A pod-start database role's TTL is not 4 days."
  }
}

run "auth_roles_bound_narrowly" {
  command = plan

  assert {
    condition = alltrue([
      for role in [
        vault_kubernetes_auth_backend_role.databases,
        vault_kubernetes_auth_backend_role.cert_manager,
        vault_kubernetes_auth_backend_role.spire_server,
        vault_kubernetes_auth_backend_role.tekton_results,
        vault_kubernetes_auth_backend_role.barman_s3,
      ] : length(role.bound_service_account_names) == 1 && length(role.bound_service_account_namespaces) == 1
    ])
    error_message = "A Kubernetes auth role is bound to more than one ServiceAccount or namespace."
  }
}

run "leaf_profile_is_scoped" {
  command = plan

  assert {
    condition = (
      vault_pki_secret_backend_role.internal_server.server_flag &&
      vault_pki_secret_backend_role.internal_server.client_flag &&
      !vault_pki_secret_backend_role.internal_server.allow_ip_sans &&
      !vault_pki_secret_backend_role.internal_server.allow_glob_domains &&
      contains(vault_pki_secret_backend_role.internal_server.allowed_domains, var.internal_domain) &&
      contains(vault_pki_secret_backend_role.internal_server.allowed_domains, "hubble-grpc.cilium.io") &&
      contains(vault_pki_secret_backend_role.internal_server.allowed_domains, "hubble-relay.cilium.io") &&
      !contains(vault_pki_secret_backend_role.internal_server.allowed_domains, "internal") &&
      !contains(vault_pki_secret_backend_role.internal_server.allowed_domains, "cilium.io")
    )
    error_message = "The shared profile must preserve Hubble mTLS while limiting names and rejecting IP SANs."
  }
}

run "policies_read_only" {
  command = plan

  assert {
    condition = alltrue([
      for policy in [
        vault_policy.databases,
        vault_policy.tekton_results,
        vault_policy.barman_s3,
      ] : length(regexall("capabilities\\s*=\\s*\\[\"read\"\\]", policy.policy)) == length(regexall("capabilities", policy.policy))
    ])
    error_message = "A policy grants more than read."
  }
}

run "cert_roles_bound_narrowly" {
  command = plan

  assert {
    condition = alltrue([
      for role in [
        vault_cert_auth_backend_role.core_test,
      ] : length(role.allowed_uri_sans) == 1
    ])
    error_message = "A cert auth role admits more than one SPIFFE ID."
  }
}

run "cert_roles_trust_root_ca" {
  command = plan

  override_resource {
    target = vault_pki_secret_backend_root_cert.root
    values = {
      certificate = "root-ca"
    }
  }

  assert {
    condition = alltrue([
      for role in [
        vault_cert_auth_backend_role.core_test,
      ] : role.certificate == vault_pki_secret_backend_root_cert.root.certificate
    ])
    error_message = "A cert auth role does not trust the OpenBao root CA that signs SPIRE's CA."
  }
}

run "seaweedfs_lease_ttl" {
  command = plan

  assert {
    condition     = vault_aws_secret_backend.seaweedfs.default_lease_ttl_seconds == 345600 && vault_aws_secret_backend.seaweedfs.max_lease_ttl_seconds == 345600
    error_message = "The seaweedfs mount's lease is not 4 days, so each daily rotation leaves a SeaweedFS IAM user alive for longer."
  }
}

run "csi_tokens_cover_secret_leases" {
  command = plan

  assert {
    condition = (
      vault_kubernetes_auth_backend_role.barman_s3.token_ttl >= vault_aws_secret_backend.seaweedfs.default_lease_ttl_seconds &&
      vault_kubernetes_auth_backend_role.barman_s3.token_max_ttl >= vault_aws_secret_backend.seaweedfs.max_lease_ttl_seconds
    )
    error_message = "Barman's CSI login token expires before its S3 lease, revoking the key before the next daily rotation."
  }

  assert {
    condition = (
      vault_kubernetes_auth_backend_role.tekton_results.token_ttl >= vault_database_secret_backend_role.tekton_results_app_role.default_ttl &&
      vault_kubernetes_auth_backend_role.tekton_results.token_max_ttl >= vault_database_secret_backend_role.tekton_results_app_role.max_ttl
    )
    error_message = "Tekton Results' CSI login token expires before its database lease, revoking the login before the next daily rotation."
  }
}
