package api

import (
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

func (h *handler) Routes() chi.Router {
	router := chi.NewRouter()

	router.Use(middleware.CleanPath)
	router.Use(middleware.Logger)
	router.Use(middleware.Recoverer)

	router.Route("/v1", func(v1 chi.Router) {
		// Internal auth routes — called by the web BFF only
		v1.Route("/auth", func(auth chi.Router) {
			auth.With(h.requireInternal).Post("/provision", h.provisionUser)
			auth.With(h.requireInternal).Delete("/account", h.deleteAccount)
		})
	})

	return router
}
