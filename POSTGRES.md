# PostgreSQL

Managed by CloudNativePG (CNPG) operator inside K3s. HA in production (1 primary + 2 replicas). Single instance in dev.

## Connection

Connection string is set via `DATABASE_URL` environment variable. The Go layer uses `pgx` directly — no ORM.

Migrations are run by the `platform-migrator` binary:
```sh
task migrate
```

## Schema

### users
Primary record for the authenticated operator.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` | PK, UUIDv7 |
| `email` | `text` | Unique |
| `name` | `text` | Display name |
| `avatar_url` | `text` | Optional |
| `tier` | `text` | Reserved, currently unused |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | |
| `deleted_at` | `timestamptz` | Soft delete |

### workspaces
Internal routing namespace. One workspace per user, created atomically on first login. Not exposed as a product concept.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` | PK, UUIDv7 |
| `name` | `text` | |
| `slug` | `text` | Unique — used in URL routing (`/{slug}`) |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | |
| `deleted_at` | `timestamptz` | Soft delete |

### workspace_members
Links user to workspace with a role. Owner role only in practice.

| Column | Type | Notes |
|---|---|---|
| `workspace_id` | `uuid` | FK → workspaces |
| `user_id` | `uuid` | FK → users |
| `role` | `text` | `owner` |
| `created_at` | `timestamptz` | |

### projects
An application being hosted. Belongs to a workspace.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` | PK, UUIDv7 |
| `workspace_id` | `uuid` | FK → workspaces |
| `name` | `text` | |
| `framework` | `text` | Language/runtime hint (`go`, `rust`, `zig`) |
| `repo_url` | `text` | Git repository |
| `default_branch` | `text` | |
| `root_directory` | `text` | |
| `build_command` | `text` | Optional |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | |

### deployments
A single deploy of a project.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` | PK, UUIDv7 |
| `project_id` | `uuid` | FK → projects |
| `environment` | `text` | `production` |
| `status` | `text` | `pending`, `building`, `success`, `failed` |
| `branch` | `text` | |
| `commit_sha` | `text` | |
| `commit_message` | `text` | |
| `deployment_url` | `text` | Optional |
| `build_started_at` | `timestamptz` | |
| `build_finished_at` | `timestamptz` | |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | |

### build_log_lines
Streaming build output, line by line.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` | PK |
| `deployment_id` | `uuid` | FK → deployments |
| `line_number` | `int` | Ordered |
| `content` | `text` | |
| `stream` | `text` | `stdout` or `stderr` |
| `created_at` | `timestamptz` | |

### project_env_vars
Encrypted environment variables per project.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` | PK |
| `project_id` | `uuid` | FK → projects |
| `environment` | `text` | `production` |
| `key_name` | `text` | |
| `encrypted_value` | `bytea` | AES-GCM encrypted |
| `encrypted_data_key` | `bytea` | Envelope encrypted via KMS |
| `encryption_iv` | `bytea` | |
| `kms_key_id` | `text` | |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | |

### domains
Custom domains attached to projects.

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` | PK |
| `project_id` | `uuid` | FK → projects |
| `domain` | `text` | |
| `is_verified` | `bool` | |
| `tls_status` | `text` | `pending`, `issued`, `error` |
| `created_at` | `timestamptz` | |

## Migrations

Files live in `core/migrations/`. Format: `NNNN_description.up.sql` / `NNNN_description.down.sql`. Run in order by `platform-migrator`.

## Backup

CNPG writes WAL and base backups to the configured S3 endpoint (`etcd_s3_*` vars in Terraform). Recovery is handled by CNPG's built-in restore flow.
