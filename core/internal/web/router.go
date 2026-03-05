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

	// Public routes
	router.Get("/", h.Splash)
	router.Get("/liquid", h.LiquidCompute)
	router.Get("/metal", h.MetalCompute)
	router.Get("/about", h.About)
	router.Get("/templates", h.Templates)
	router.Get("/templates/{slug}", h.TemplateDetail)
	router.Get("/changelog", h.Changelog)
	router.Get("/pricing", h.Pricing)
	router.Get("/healthz", h.Healthz)
	router.Get("/docs", h.Docs)
	router.Get("/docs/*", h.Docs)

	// Authentication flow — must be full page navigations, never HTMX
	router.Route("/auth", func(auth chi.Router) {
		auth.Get("/login", h.AuthLogin)
		auth.Get("/callback", h.AuthCallback)
		auth.Get("/logout", h.AuthLogout)     // kept for direct URL navigation
		auth.Post("/logout", h.AuthLogout)    // form POST from the Sign Out button
		auth.Get("/cli/login", h.AuthCLILogin)
		auth.Get("/cli/callback", h.AuthCLICallback)
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
		protected.Get("/{slug}/webhooks", h.DashboardWebhooks)
		protected.Get("/{slug}/billing", h.DashboardBilling)
		protected.Get("/{slug}/blueprints", h.DashboardBlueprints)
		protected.Get("/{slug}/env-groups", h.DashboardEnvGroups)
		protected.Get("/{slug}/observability", h.DashboardObservability)
		protected.Get("/{slug}/notifications", h.DashboardNotifications)
		protected.Get("/{slug}/private-links", h.DashboardPrivateLinks)
		protected.Get("/{slug}/settings", h.DashboardSettings)
		protected.Get("/settings", h.Settings)
		protected.Get("/account", h.Account)
		protected.Post("/account/delete", h.AccountDelete)
		protected.Get("/new-workspace", h.NewWorkspace)
		protected.Post("/new-workspace", h.NewWorkspacePost)
	})

	return router
}
