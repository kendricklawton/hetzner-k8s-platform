package api

import (
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/kendricklawton/project-platform/gen/go/platform/v1/platformv1connect"
)

func (h *handler) Routes() chi.Router {
	router := chi.NewRouter()

	router.Use(middleware.CleanPath)
	router.Use(middleware.Logger)
	router.Use(middleware.Recoverer)

	router.Route("/v1", func(v1 chi.Router) {
		// --- Internal Auth Routes (called by the web BFF) ---
		v1.Route("/auth", func(auth chi.Router) {
			auth.With(h.requireInternal).Post("/provision", h.provisionUser)
			auth.With(h.requireInternal).Delete("/account", h.deleteAccount)
		})

		// --- CLI REST Routes ---
		v1.Group(func(cli chi.Router) {
			cli.Use(h.requireAuth)
			cli.Get("/services", h.listServices)
			cli.Get("/revisions", h.listRevisions)
			cli.Get("/logs", h.getLogs)
			cli.Post("/deploy", h.deploy)
			cli.Get("/secrets", h.listSecrets)
		})

		// --- RPC Routes (Core API Platform) ---
		v1.Group(func(rpc chi.Router) {
			rpc.Use(h.requireAuth)

			// Mount ConnectRPC handlers utilizing the DI-injected services
			workspacePath, workspaceHandler := platformv1connect.NewWorkspaceServiceHandler(h.Services.Workspace)
			rpc.Mount(workspacePath, workspaceHandler)

			userPath, userHandler := platformv1connect.NewUserServiceHandler(h.Services.User)
			rpc.Mount(userPath, userHandler)
		})
	})

	return router
}
