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
	router.Get("/about", h.About)
	router.Get("/changelog", h.Changelog)
	router.Get("/pricing", h.Pricing)
	router.Get("/healthz", h.Healthz)
	router.Get("/docs", h.Docs)
	router.Get("/docs/*", h.Docs)

	// Authentication flow — must be full page navigations, never HTMX
	router.Route("/auth", func(auth chi.Router) {
		auth.Get("/login", h.AuthLogin)
		auth.Get("/callback", h.AuthCallback)
		auth.Get("/logout", h.AuthLogout)  // kept for direct URL navigation
		auth.Post("/logout", h.AuthLogout) // form POST from the Sign Out button
	})

	// Protected routes — all behind RequireAuth middleware
	router.Group(func(protected chi.Router) {
		protected.Use(h.RequireAuth)
		protected.Get("/dashboard", h.Dashboard)
		protected.Get("/settings", h.Settings)
	})

	return router
}
