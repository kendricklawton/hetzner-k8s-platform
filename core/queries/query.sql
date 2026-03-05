-- ============================================================================
-- QUERIES: sqlc query definitions
-- Naming: sqlc conventions (:one, :many, :exec, :execrows, :copyfrom)
-- Auth pattern: WHERE EXISTS subquery for RBAC inline with mutations
-- ============================================================================

-- ============================================================================
-- USERS
-- ============================================================================

-- name: CreateUser :one
INSERT INTO users (id, email, name) VALUES ($1, $2, $3) RETURNING *;

-- name: GetUser :one
SELECT * FROM users WHERE id = $1 AND deleted_at IS NULL;

-- name: GetUserByEmail :one
SELECT * FROM users WHERE email = $1 AND deleted_at IS NULL;

-- name: UpdateUserTier :one
UPDATE users SET tier = $2 WHERE id = $1 RETURNING *;

-- name: UpdateUserStripeCustomerID :one
UPDATE users SET stripe_customer_id = $2 WHERE id = $1 RETURNING *;

-- name: UpdateUserProfile :one
UPDATE users SET name = $2, avatar_url = $3 WHERE id = $1 RETURNING *;

-- name: DeleteOrphanedWorkspaces :exec
UPDATE workspaces SET deleted_at = NOW() WHERE id IN (
    SELECT wm.workspace_id FROM workspace_members wm
    WHERE wm.user_id = $1 AND wm.role = 'owner'
    AND NOT EXISTS (
        SELECT 1 FROM workspace_members wm2
        WHERE wm2.workspace_id = wm.workspace_id AND wm2.user_id != $1
    )
) AND deleted_at IS NULL;

-- name: DeleteUser :exec
UPDATE users SET deleted_at = NOW() WHERE id = $1 AND deleted_at IS NULL;

-- ============================================================================
-- WORKSPACES
-- ============================================================================

-- name: CreateWorkspaceWithOwner :one
-- Atomic CTE: Creates a workspace and immediately assigns the creator as the owner.
-- Bypasses the chicken-and-egg RBAC problem natively in Postgres.
WITH new_workspace AS (
    INSERT INTO workspaces (id, name, slug) VALUES ($1, $2, $3) RETURNING *
),
new_member AS (
    INSERT INTO workspace_members (workspace_id, user_id, role)
    SELECT id, $4, 'owner' FROM new_workspace
)
SELECT * FROM new_workspace;

-- name: GetWorkspace :one
SELECT * FROM workspaces WHERE id = $1;

-- name: GetWorkspaceBySlug :one
SELECT * FROM workspaces WHERE slug = $1 AND deleted_at IS NULL;

-- name: GetWorkspacesForUser :many
SELECT w.*, wm.role FROM workspaces w
JOIN workspace_members wm ON w.id = wm.workspace_id
WHERE wm.user_id = $1 AND w.deleted_at IS NULL
ORDER BY w.name;

-- name: UpdateWorkspace :one
UPDATE workspaces SET name = $2, slug = $3
WHERE workspaces.id = $1
AND EXISTS (
    SELECT 1 FROM workspace_members wm
    WHERE wm.workspace_id = $1 AND wm.user_id = $4 AND wm.role = 'owner'
)
RETURNING *;

-- ============================================================================
-- ONBOARDING
-- ============================================================================

-- name: OnboardUserWithWorkspace :one
-- Atomic: creates user + personal workspace + owner membership in one transaction
WITH new_user AS (
    INSERT INTO users (id, email, name) VALUES ($1, $2, $3) RETURNING id
),
new_workspace AS (
    INSERT INTO workspaces (id, name, slug) VALUES ($4, $5, $6) RETURNING id
)
INSERT INTO workspace_members (workspace_id, user_id, role)
SELECT new_workspace.id, new_user.id, 'owner'
FROM new_user, new_workspace
RETURNING workspace_members.workspace_id;

-- ============================================================================
-- WORKSPACE MEMBERS
-- ============================================================================

-- name: AddWorkspaceMember :one
INSERT INTO workspace_members (workspace_id, user_id, role)
SELECT $1, $2, $3
WHERE EXISTS (
    SELECT 1 FROM workspace_members wm
    WHERE wm.workspace_id = $1 AND wm.user_id = $4 AND wm.role = 'owner'
)
RETURNING *;

-- name: UpdateWorkspaceMemberRole :execrows
UPDATE workspace_members SET role = $3
WHERE workspace_members.workspace_id = $1 AND workspace_members.user_id = $2
AND EXISTS (
    SELECT 1 FROM workspace_members wm
    WHERE wm.workspace_id = $1 AND wm.user_id = $4 AND wm.role = 'owner'
)
AND NOT (
    $3 != 'owner' AND (
        SELECT COUNT(*) FROM workspace_members wm2
        WHERE wm2.workspace_id = $1 AND wm2.role = 'owner'
    ) <= 1 AND workspace_members.user_id = (
        SELECT wm3.user_id FROM workspace_members wm3
        WHERE wm3.workspace_id = $1 AND wm3.role = 'owner' LIMIT 1
    )
);

-- name: RemoveWorkspaceMember :execrows
DELETE FROM workspace_members
WHERE workspace_members.workspace_id = $1 AND workspace_members.user_id = $2
AND EXISTS (
    SELECT 1 FROM workspace_members wm
    WHERE wm.workspace_id = $1 AND wm.user_id = $3 AND wm.role = 'owner'
)
AND NOT (
    workspace_members.role = 'owner' AND (
        SELECT COUNT(*) FROM workspace_members wm2
        WHERE wm2.workspace_id = $1 AND wm2.role = 'owner'
    ) <= 1
);

-- name: ListWorkspaceMembers :many
SELECT wm.*, u.email, u.name, u.avatar_url FROM workspace_members wm
JOIN users u ON wm.user_id = u.id
WHERE wm.workspace_id = $1
ORDER BY wm.role, u.name;

-- name: GetWorkspaceMember :one
SELECT wm.*, u.email, u.name FROM workspace_members wm
JOIN users u ON wm.user_id = u.id
WHERE wm.workspace_id = $1 AND wm.user_id = $2;

-- ============================================================================
-- PROJECTS
-- ============================================================================

-- name: CreateProject :one
INSERT INTO projects (id, workspace_id, name, framework, repo_url, default_branch, root_directory, build_command, install_command, output_directory)
SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
WHERE EXISTS (
    SELECT 1 FROM workspace_members wm
    WHERE wm.workspace_id = $2 AND wm.user_id = $11 AND wm.role IN ('owner', 'member')
)
RETURNING *;

-- name: GetProject :one
SELECT p.* FROM projects p
JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
WHERE p.id = $1 AND wm.user_id = $2;

-- name: ListWorkspaceProjects :many
SELECT p.* FROM projects p
JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
WHERE p.workspace_id = $1 AND wm.user_id = $2
ORDER BY p.created_at DESC;

-- name: UpdateProject :one
UPDATE projects SET
    name = COALESCE(NULLIF($3, ''), name),
    framework = COALESCE(NULLIF($4, ''), framework),
    repo_url = COALESCE(NULLIF($5, ''), repo_url),
    default_branch = COALESCE(NULLIF($6, ''), default_branch),
    root_directory = COALESCE(NULLIF($7, ''), root_directory),
    build_command = $8,
    install_command = $9,
    output_directory = $10
WHERE projects.id = $1
AND EXISTS (
    SELECT 1 FROM projects p
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE p.id = projects.id AND wm.user_id = $2 AND wm.role IN ('owner', 'member')
)
RETURNING *;

-- name: DeleteProject :execrows
DELETE FROM projects
WHERE projects.id = $1
AND EXISTS (
    SELECT 1 FROM projects p
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE p.id = projects.id AND wm.user_id = $2 AND wm.role = 'owner'
);

-- ============================================================================
-- DOMAINS
-- ============================================================================

-- name: AddDomain :one
INSERT INTO domains (id, project_id, domain)
SELECT $1, $2, $3
WHERE EXISTS (
    SELECT 1 FROM projects p
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE p.id = $2 AND wm.user_id = $4 AND wm.role IN ('owner', 'member')
)
RETURNING *;

-- name: ListProjectDomains :many
SELECT d.* FROM domains d
JOIN projects p ON d.project_id = p.id
JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
WHERE d.project_id = $1 AND wm.user_id = $2
ORDER BY d.created_at DESC;

-- name: VerifyDomain :one
UPDATE domains SET is_verified = true, tls_status = 'provisioning'
WHERE domains.id = $1 RETURNING *;

-- name: UpdateDomainTLSStatus :one
UPDATE domains SET tls_status = $2
WHERE domains.id = $1 RETURNING *;

-- name: DeleteDomain :execrows
DELETE FROM domains
WHERE domains.id = $1
AND EXISTS (
    SELECT 1 FROM domains d
    JOIN projects p ON d.project_id = p.id
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE d.id = domains.id AND wm.user_id = $2 AND wm.role IN ('owner', 'member')
);

-- name: GetDomainByName :one
SELECT d.*, p.id AS project_id, p.workspace_id FROM domains d
JOIN projects p ON d.project_id = p.id
WHERE d.domain = $1 AND d.is_verified = true AND d.tls_status = 'active';

-- ============================================================================
-- SECRETS MANAGEMENT
-- ============================================================================

-- name: UpsertEnvVar :one
INSERT INTO project_env_vars (id, project_id, environment, key_name, encrypted_value, encrypted_data_key, encryption_iv, kms_key_id)
SELECT $1, $2, $3, $4, $5, $6, $7, $8
WHERE EXISTS (
    SELECT 1 FROM projects p
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE p.id = $2 AND wm.user_id = $9 AND wm.role IN ('owner', 'member')
)
ON CONFLICT (project_id, environment, key_name)
DO UPDATE SET
    encrypted_value = EXCLUDED.encrypted_value,
    encrypted_data_key = EXCLUDED.encrypted_data_key,
    encryption_iv = EXCLUDED.encryption_iv,
    kms_key_id = EXCLUDED.kms_key_id
RETURNING *;

-- name: DeleteEnvVar :execrows
DELETE FROM project_env_vars
WHERE project_id = $1 AND environment = $2 AND key_name = $3
AND EXISTS (
    SELECT 1 FROM projects p
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE p.id = $1 AND wm.user_id = $4 AND wm.role IN ('owner', 'member')
);

-- name: ListEnvVarKeys :many
SELECT id, key_name, environment, kms_key_id, created_at, updated_at
FROM project_env_vars
WHERE project_id = $1
AND EXISTS (
    SELECT 1 FROM projects p
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE p.id = $1 AND wm.user_id = $2
)
ORDER BY environment, key_name;

-- name: GetEnvVarsForDeployment :many
SELECT key_name, encrypted_value, encrypted_data_key, encryption_iv, kms_key_id
FROM project_env_vars
WHERE project_id = $1 AND environment = $2;

-- ============================================================================
-- WEBHOOKS
-- ============================================================================

-- name: CreateWebhook :one
INSERT INTO webhooks (id, project_id, provider, provider_install_id, hook_secret_encrypted, events)
SELECT $1, $2, $3, $4, $5, $6
WHERE EXISTS (
    SELECT 1 FROM projects p
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE p.id = $2 AND wm.user_id = $7 AND wm.role IN ('owner', 'member')
)
RETURNING *;

-- name: GetWebhookByProviderInstall :one
SELECT w.*, p.workspace_id FROM webhooks w
JOIN projects p ON w.project_id = p.id
WHERE w.provider = $1 AND w.provider_install_id = $2 AND w.is_active = true;

-- name: ListProjectWebhooks :many
SELECT w.* FROM webhooks w
JOIN projects p ON w.project_id = p.id
JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
WHERE w.project_id = $1 AND wm.user_id = $2
ORDER BY w.created_at DESC;

-- name: DeleteWebhook :execrows
DELETE FROM webhooks
WHERE webhooks.id = $1
AND EXISTS (
    SELECT 1 FROM webhooks w
    JOIN projects p ON w.project_id = p.id
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE w.id = webhooks.id AND wm.user_id = $2 AND wm.role IN ('owner', 'member')
);

-- ============================================================================
-- DEPLOYMENTS
-- ============================================================================

-- name: CreateDeployment :one
INSERT INTO deployments (id, project_id, environment, branch, commit_sha, commit_message)
SELECT $1, $2, $3, $4, $5, $6
WHERE EXISTS (
    SELECT 1 FROM projects p
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE p.id = $2 AND wm.user_id = $7 AND wm.role IN ('owner', 'member')
)
RETURNING *;

-- name: GetDeployment :one
SELECT d.* FROM deployments d
JOIN projects p ON d.project_id = p.id
JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
WHERE d.id = $1 AND wm.user_id = $2 AND d.deleted_at IS NULL;

-- name: ListProjectDeployments :many
SELECT d.* FROM deployments d
JOIN projects p ON d.project_id = p.id
JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
WHERE d.project_id = $1 AND wm.user_id = $2 AND d.deleted_at IS NULL
ORDER BY d.created_at DESC
LIMIT $3 OFFSET $4;

-- name: GetLatestDeployment :one
SELECT * FROM deployments
WHERE project_id = $1 AND environment = $2 AND status = 'ready' AND deleted_at IS NULL
ORDER BY created_at DESC
LIMIT 1;

-- name: UpdateDeploymentStatus :one
UPDATE deployments SET
    status = $2,
    deployment_url = COALESCE($3, deployment_url),
    build_logs_uri = COALESCE($4, build_logs_uri),
    build_started_at = CASE WHEN $2 = 'building' AND build_started_at IS NULL THEN NOW() ELSE build_started_at END,
    build_finished_at = CASE WHEN $2 IN ('ready', 'error', 'canceled') AND build_finished_at IS NULL THEN NOW() ELSE build_finished_at END
WHERE deployments.id = $1
RETURNING *;

-- name: CancelDeployment :one
UPDATE deployments SET status = 'canceled'
WHERE deployments.id = $1 AND deployments.status IN ('queued', 'building')
AND EXISTS (
    SELECT 1 FROM projects p
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE p.id = deployments.project_id AND wm.user_id = $2 AND wm.role IN ('owner', 'member')
)
RETURNING *;

-- name: SoftDeleteDeployment :execrows
UPDATE deployments SET deleted_at = NOW()
WHERE deployments.id = $1 AND deployments.deleted_at IS NULL
AND EXISTS (
    SELECT 1 FROM projects p
    JOIN workspace_members wm ON p.workspace_id = wm.workspace_id
    WHERE p.id = deployments.project_id AND wm.user_id = $2 AND wm.role = 'owner'
);

-- name: CountQueuedDeployments :one
SELECT COUNT(*) FROM deployments
WHERE status IN ('queued', 'building') AND deleted_at IS NULL;

-- name: CountWorkspaceQueuedDeployments :one
SELECT COUNT(*) FROM deployments d
JOIN projects p ON d.project_id = p.id
WHERE p.workspace_id = $1 AND d.status IN ('queued', 'building') AND d.deleted_at IS NULL;

-- name: GetStaleBuilds :many
SELECT * FROM deployments
WHERE status = 'building'
AND build_started_at < NOW() - INTERVAL '30 minutes'
AND deleted_at IS NULL
ORDER BY build_started_at
LIMIT 50;

-- ============================================================================
-- BUILD LOG LINES
-- ============================================================================

-- name: InsertBuildLogLine :exec
INSERT INTO build_log_lines (id, deployment_id, line_number, content, stream, created_at)
VALUES ($1, $2, $3, $4, $5, $6);

-- name: InsertBuildLogBatch :copyfrom
INSERT INTO build_log_lines (id, deployment_id, line_number, content, stream, created_at)
VALUES ($1, $2, $3, $4, $5, $6);

-- name: GetBuildLogs :many
SELECT line_number, content, stream, created_at
FROM build_log_lines
WHERE deployment_id = $1
AND line_number > $2
ORDER BY line_number
LIMIT $3;

-- name: GetBuildLogCount :one
SELECT COUNT(*) FROM build_log_lines WHERE deployment_id = $1;

-- ============================================================================
-- AUDIT LOG
-- ============================================================================

-- name: CreateAuditEntry :exec
INSERT INTO audit_log (id, workspace_id, actor_id, action, resource_type, resource_id, metadata, ip_address, user_agent, created_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10);

-- name: ListWorkspaceAuditLog :many
SELECT al.*, u.email AS actor_email, u.name AS actor_name
FROM audit_log al
LEFT JOIN users u ON al.actor_id = u.id
WHERE al.workspace_id = $1
AND al.created_at >= $2
AND al.created_at < $3
ORDER BY al.created_at DESC
LIMIT $4 OFFSET $5;

-- name: ListResourceAuditLog :many
SELECT al.*, u.email AS actor_email, u.name AS actor_name
FROM audit_log al
LEFT JOIN users u ON al.actor_id = u.id
WHERE al.resource_type = $1 AND al.resource_id = $2
AND al.created_at >= $3
AND al.created_at < $4
ORDER BY al.created_at DESC
LIMIT $5;

-- ============================================================================
-- USAGE / BILLING
-- ============================================================================

-- name: RecordUsage :exec
INSERT INTO usage_records (id, workspace_id, metric, quantity, period_start, period_end)
VALUES ($1, $2, $3, $4, $5, $6);

-- name: GetWorkspaceUsageSummary :many
SELECT metric, SUM(quantity) AS total
FROM usage_records
WHERE workspace_id = $1 AND period_start >= $2 AND period_end <= $3
GROUP BY metric;

-- name: GetWorkspaceUsageDetail :many
SELECT * FROM usage_records
WHERE workspace_id = $1 AND metric = $2 AND period_start >= $3
ORDER BY period_start DESC
LIMIT $4;
