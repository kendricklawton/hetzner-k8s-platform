-- ============================================================================
-- MIGRATION 0003 DOWN: Revert workspaces back to teams
-- ============================================================================

ALTER INDEX idx_usage_workspace_metric        RENAME TO idx_usage_team_metric;
ALTER INDEX idx_usage_workspace_period        RENAME TO idx_usage_team_period;
ALTER INDEX idx_audit_workspace_created       RENAME TO idx_audit_team_created;
ALTER INDEX idx_projects_workspace_created    RENAME TO idx_projects_team_created;
ALTER INDEX idx_workspace_members_user        RENAME TO idx_team_members_user;

ALTER TRIGGER trg_workspaces_updated_at ON workspaces RENAME TO trg_teams_updated_at;

ALTER TABLE usage_records     RENAME COLUMN workspace_id TO team_id;
ALTER TABLE audit_log         RENAME COLUMN workspace_id TO team_id;
ALTER TABLE projects          RENAME COLUMN workspace_id TO team_id;
ALTER TABLE workspace_members RENAME COLUMN workspace_id TO team_id;

ALTER TABLE workspace_members RENAME TO team_members;
ALTER TABLE workspaces        RENAME TO teams;
