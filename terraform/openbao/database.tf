resource "vault_mount" "db" {
  path = "database"
  type = "database"
}

resource "vault_database_secret_backend_connection" "postgres_cluster" {
  backend       = vault_mount.db.path
  name          = "postgres-cluster"
  allowed_roles = ["postgres-app-role", "tekton-results-app-role"]
  # postgres-cluster-rw is created later in the Flux chain, downstream of this apply.
  verify_connection = false

  postgresql {
    connection_url      = "postgresql://{{username}}:{{password}}@postgres-cluster-rw.databases.svc.cluster.local:5432/postgres?sslmode=require"
    username            = "postgres"
    password_wo         = var.postgres_superuser_password
    password_wo_version = var.secrets_wo_version
  }
}

resource "vault_database_secret_backend_role" "postgres_app_role" {
  backend = vault_mount.db.path
  name    = "postgres-app-role"
  db_name = vault_database_secret_backend_connection.postgres_cluster.name
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE app_readwrite; ALTER ROLE \"{{name}}\" SET role = app_readwrite;"
  ]
  default_ttl = 10800 # 3h
  max_ttl     = 86400 # 24h
}

resource "vault_database_secret_backend_role" "tekton_results_app_role" {
  backend = vault_mount.db.path
  name    = "tekton-results-app-role"
  db_name = vault_database_secret_backend_connection.postgres_cluster.name
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE tekton_readwrite; ALTER ROLE \"{{name}}\" SET role = tekton_readwrite;"
  ]
  default_ttl = 345600 # 4d
  max_ttl     = 345600 # 4d
}
