package web

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

func (h *Handler) Routes() chi.Router {
	router := chi.NewRouter()

	router.Use(middleware.Logger)
	router.Use(middleware.Recoverer)

	// Static assets
	fileServer := http.FileServer(http.Dir("internal/web/ui/static"))
	router.Handle("/static/*", http.StripPrefix("/static/", fileServer))

	// Root → redirect to dashboard or login
	router.Get("/", h.RootRedirect)
	router.Get("/healthz", h.Healthz)

	// Authentication flow — must be full page navigations, never HTMX
	router.Route("/auth", func(auth chi.Router) {
		auth.Get("/login", h.AuthLogin)
		auth.Get("/callback", h.AuthCallback)
		auth.Get("/logout", h.AuthLogout)
		auth.Post("/logout", h.AuthLogout)
	})

	// /dashboard → redirect to /{slug} using the slug cookie
	router.Get("/dashboard", h.DashboardRedirect)

	// Protected routes — slug-scoped, all behind RequireAuth middleware
	router.Group(func(protected chi.Router) {
		protected.Use(h.RequireAuth)
		protected.Get("/{slug}", h.Dashboard)
		protected.Get("/{slug}/projects/{projectID}", h.Project)
		protected.Get("/{slug}/services", h.DashboardServices)
		protected.Get("/{slug}/deployments", h.DashboardDeployments)
		protected.Get("/{slug}/logs", h.DashboardLogs)
		protected.Get("/{slug}/secrets", h.DashboardSecrets)
		protected.Get("/{slug}/domains", h.DashboardDomains)
		protected.Get("/{slug}/observability", h.DashboardObservability)
		protected.Get("/{slug}/settings", h.DashboardSettings)
		protected.Get("/settings", h.Settings)
		protected.Get("/account", h.Account)
		protected.Post("/account/delete", h.AccountDelete)
	})

	return router
}
