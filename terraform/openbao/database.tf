resource "vault_mount" "db" {
  path = "database"
  type = "database"
}

resource "vault_database_secret_backend_connection" "postgis_cluster" {
  backend       = vault_mount.db.path
  name          = "postgis-cluster"
  allowed_roles = ["postgis-app-role", "tekton-results-app-role"]
  # postgis-cluster-rw is created later in the Flux chain, downstream of this apply.
  verify_connection = false

  postgresql {
    connection_url      = "postgresql://{{username}}:{{password}}@postgis-cluster-rw.databases.svc.cluster.local:5432/postgres?sslmode=require"
    username            = "postgres"
    password_wo         = var.postgres_superuser_password
    password_wo_version = var.secrets_wo_version
  }
}

resource "vault_database_secret_backend_role" "postgis_app_role" {
  backend = vault_mount.db.path
  name    = "postgis-app-role"
  db_name = vault_database_secret_backend_connection.postgis_cluster.name
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE app_readwrite; ALTER ROLE \"{{name}}\" SET role = app_readwrite;"
  ]
  default_ttl = 10800 # 3h
  max_ttl     = 86400 # 24h
}

resource "vault_database_secret_backend_role" "tekton_results_app_role" {
  backend = vault_mount.db.path
  name    = "tekton-results-app-role"
  db_name = vault_database_secret_backend_connection.postgis_cluster.name
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE tekton_readwrite; ALTER ROLE \"{{name}}\" SET role = tekton_readwrite;"
  ]
  # Each Results pod start mints a login that must outlive the pod
  default_ttl = 2764800 # 32d
  max_ttl     = 2764800 # 32d
}
