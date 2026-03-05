-- ============================================================================
-- MIGRATION 0003: Rename "teams" concept to "workspaces"
-- ============================================================================

-- 1. Rename tables
ALTER TABLE teams        RENAME TO workspaces;
ALTER TABLE team_members RENAME TO workspace_members;

-- 2. Rename primary key / foreign key columns
ALTER TABLE workspace_members RENAME COLUMN team_id TO workspace_id;
ALTER TABLE projects          RENAME COLUMN team_id TO workspace_id;
ALTER TABLE audit_log         RENAME COLUMN team_id TO workspace_id;
ALTER TABLE usage_records     RENAME COLUMN team_id TO workspace_id;

-- 3. Rename triggers
ALTER TRIGGER trg_teams_updated_at ON workspaces RENAME TO trg_workspaces_updated_at;

-- 4. Rename indexes
ALTER INDEX idx_team_members_user        RENAME TO idx_workspace_members_user;
ALTER INDEX idx_projects_team_created    RENAME TO idx_projects_workspace_created;
ALTER INDEX idx_audit_team_created       RENAME TO idx_audit_workspace_created;
ALTER INDEX idx_usage_team_period        RENAME TO idx_usage_workspace_period;
ALTER INDEX idx_usage_team_metric        RENAME TO idx_usage_workspace_metric;

-- 5. Rename UNIQUE constraint on projects (team_id, name) → (workspace_id, name)
-- The constraint was created implicitly as UNIQUE(team_id, name); rename it.
DO $$
DECLARE
    cname TEXT;
BEGIN
    SELECT conname INTO cname
    FROM pg_constraint
    WHERE conrelid = 'projects'::regclass
      AND contype = 'u'
      AND array_length(conkey, 1) = 2;
    IF cname IS NOT NULL THEN
        EXECUTE format('ALTER TABLE projects RENAME CONSTRAINT %I TO projects_workspace_id_name_key', cname);
    END IF;
END $$;
