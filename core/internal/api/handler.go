package api

import (
	"github.com/kendricklawton/project-platform/core/internal/db"
	"github.com/kendricklawton/project-platform/core/internal/k8s"
	"github.com/kendricklawton/project-platform/core/internal/service"
)

// Services holds pointers to your actual Business Logic (The internal services).
type Services struct {
	Workspace *service.WorkspaceServer
	User *service.UserServer
	Auth *service.AuthService
}

// Handler is the core API layer.
type handler struct {
	K8s            *k8s.Client
	Store          db.Store
	InternalSecret string
	Services       Services
}

// NewHandler creates a new API Handler with all injected dependencies.
func NewHandler(k8s *k8s.Client, store db.Store, internalSecret string, svcs Services) *handler {
	return &handler{
		K8s:            k8s,
		Store:          store,
		InternalSecret: internalSecret,
		Services:       svcs,
	}
}
