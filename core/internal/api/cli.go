package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"

	"github.com/google/uuid"
	"github.com/kendricklawton/project-platform/core/internal/db"
)

// findProjectByName looks up a project by name across all workspaces the user belongs to.
func (h *handler) findProjectByName(ctx context.Context, userID uuid.UUID, name string) (*db.Project, error) {
	workspaces, err := h.Store.GetWorkspacesForUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	for _, workspace := range workspaces {
		projects, err := h.Store.ListWorkspaceProjects(ctx, db.ListWorkspaceProjectsParams{
			WorkspaceID: workspace.ID,
			UserID: userID,
		})
		if err != nil {
			continue
		}
		for _, p := range projects {
			if p.Name == name {
				return &p, nil
			}
		}
	}
	return nil, fmt.Errorf("project %q not found", name)
}

// GET /v1/services
// Returns all projects across the user's workspaces with their latest deployment status.
func (h *handler) listServices(w http.ResponseWriter, r *http.Request) {
	userID, _ := r.Context().Value(userIDKey).(uuid.UUID)

	workspaces, err := h.Store.GetWorkspacesForUser(r.Context(), userID)
	if err != nil {
		log.Printf("listServices: GetWorkspacesForUser: %v", err)
		http.Error(w, "Failed to fetch services", http.StatusInternalServerError)
		return
	}

	type serviceRow struct {
		Name     string `json:"name"`
		Lang     string `json:"lang"`
		Status   string `json:"status"`
		Revision string `json:"revision"`
		URL      string `json:"url"`
	}

	services := make([]serviceRow, 0)
	for _, workspace := range workspaces {
		projects, err := h.Store.ListWorkspaceProjects(r.Context(), db.ListWorkspaceProjectsParams{
			WorkspaceID: workspace.ID,
			UserID: userID,
		})
		if err != nil {
			continue
		}
		for _, p := range projects {
			svc := serviceRow{Name: p.Name, Lang: p.Framework, Status: "not deployed"}
			dep, err := h.Store.GetLatestDeployment(r.Context(), db.GetLatestDeploymentParams{
				ProjectID:   p.ID,
				Environment: "production",
			})
			if err == nil {
				svc.Status = dep.Status
				sha := dep.CommitSha
				if len(sha) > 7 {
					sha = sha[:7]
				}
				svc.Revision = sha
				if dep.DeploymentUrl.Valid {
					svc.URL = dep.DeploymentUrl.String
				}
			}
			services = append(services, svc)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(services)
}

// GET /v1/revisions?service=name&limit=N
func (h *handler) listRevisions(w http.ResponseWriter, r *http.Request) {
	userID, _ := r.Context().Value(userIDKey).(uuid.UUID)

	service := r.URL.Query().Get("service")
	if service == "" {
		http.Error(w, "service query param required", http.StatusBadRequest)
		return
	}

	limit := int32(10)
	if l, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && l > 0 {
		limit = int32(l)
	}

	project, err := h.findProjectByName(r.Context(), userID, service)
	if err != nil {
		http.Error(w, "service not found", http.StatusNotFound)
		return
	}

	deployments, err := h.Store.ListProjectDeployments(r.Context(), db.ListProjectDeploymentsParams{
		ProjectID: project.ID,
		UserID:    userID,
		Limit:     limit,
		Offset:    0,
	})
	if err != nil {
		log.Printf("listRevisions: %v", err)
		http.Error(w, "Failed to fetch revisions", http.StatusInternalServerError)
		return
	}

	type revisionRow struct {
		ID        string `json:"id"`
		Status    string `json:"status"`
		CreatedAt string `json:"created_at"`
		Message   string `json:"message"`
	}

	rows := make([]revisionRow, 0, len(deployments))
	for _, d := range deployments {
		rows = append(rows, revisionRow{
			ID:        d.ID.String(),
			Status:    d.Status,
			CreatedAt: d.CreatedAt.Time.Format("2006-01-02 15:04:05"),
			Message:   d.CommitMessage,
		})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(rows)
}

// GET /v1/logs?service=name
// Returns build log lines for the latest production deployment of the service.
func (h *handler) getLogs(w http.ResponseWriter, r *http.Request) {
	userID, _ := r.Context().Value(userIDKey).(uuid.UUID)

	service := r.URL.Query().Get("service")
	if service == "" {
		http.Error(w, "service query param required", http.StatusBadRequest)
		return
	}

	project, err := h.findProjectByName(r.Context(), userID, service)
	if err != nil {
		http.Error(w, "service not found", http.StatusNotFound)
		return
	}

	dep, err := h.Store.GetLatestDeployment(r.Context(), db.GetLatestDeploymentParams{
		ProjectID:   project.ID,
		Environment: "production",
	})
	if err != nil {
		http.Error(w, "no deployments found", http.StatusNotFound)
		return
	}

	lines, err := h.Store.GetBuildLogs(r.Context(), db.GetBuildLogsParams{
		DeploymentID: dep.ID,
		LineNumber:   0,
		Limit:        1000,
	})
	if err != nil {
		log.Printf("getLogs: %v", err)
		http.Error(w, "Failed to fetch logs", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	for _, line := range lines {
		fmt.Fprintf(w, "%s\n", line.Content)
	}
}

// POST /v1/deploy
// Queues a deployment for a service. The build worker picks it up asynchronously.
func (h *handler) deploy(w http.ResponseWriter, r *http.Request) {
	userID, _ := r.Context().Value(userIDKey).(uuid.UUID)

	var req struct {
		Service       string `json:"service"`
		Branch        string `json:"branch"`
		CommitSha     string `json:"commit_sha"`
		CommitMessage string `json:"commit_message"`
		Wait          bool   `json:"wait"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}
	if req.Service == "" {
		http.Error(w, "service is required", http.StatusBadRequest)
		return
	}

	project, err := h.findProjectByName(r.Context(), userID, req.Service)
	if err != nil {
		http.Error(w, "service not found", http.StatusNotFound)
		return
	}

	branch := req.Branch
	if branch == "" {
		branch = project.DefaultBranch
	}
	commitSha := req.CommitSha
	if commitSha == "" {
		commitSha = "unknown"
	}
	commitMsg := req.CommitMessage
	if commitMsg == "" {
		commitMsg = "Deployed via CLI"
	}

	deployID, err := uuid.NewV7()
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}

	dep, err := h.Store.CreateDeployment(r.Context(), db.CreateDeploymentParams{
		ID:            deployID,
		ProjectID:     project.ID,
		Environment:   "production",
		Branch:        branch,
		CommitSha:     commitSha,
		CommitMessage: commitMsg,
		UserID:        userID,
	})
	if err != nil {
		log.Printf("deploy: CreateDeployment: %v", err)
		http.Error(w, "Failed to queue deployment", http.StatusInternalServerError)
		return
	}

	url := ""
	if dep.DeploymentUrl.Valid {
		url = dep.DeploymentUrl.String
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"id":     dep.ID.String(),
		"status": dep.Status,
		"url":    url,
	})
}

// GET /v1/secrets?service=name
// Returns env var key names (not values) for a service.
func (h *handler) listSecrets(w http.ResponseWriter, r *http.Request) {
	userID, _ := r.Context().Value(userIDKey).(uuid.UUID)

	service := r.URL.Query().Get("service")
	if service == "" {
		http.Error(w, "service query param required", http.StatusBadRequest)
		return
	}

	project, err := h.findProjectByName(r.Context(), userID, service)
	if err != nil {
		http.Error(w, "service not found", http.StatusNotFound)
		return
	}

	keys, err := h.Store.ListEnvVarKeys(r.Context(), db.ListEnvVarKeysParams{
		ProjectID: project.ID,
		UserID:    userID,
	})
	if err != nil {
		log.Printf("listSecrets: %v", err)
		http.Error(w, "Failed to fetch secrets", http.StatusInternalServerError)
		return
	}

	names := make([]string, 0, len(keys))
	for _, k := range keys {
		names = append(names, k.KeyName)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(names)
}
