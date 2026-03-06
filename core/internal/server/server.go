package server

import (
	"context"
	"fmt"
	"net/http"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"

	"github.com/kendricklawton/project-platform/core/internal/api"
	"github.com/kendricklawton/project-platform/core/internal/config"
	"github.com/kendricklawton/project-platform/core/internal/db"
	"github.com/kendricklawton/project-platform/core/internal/k8s"
	"github.com/kendricklawton/project-platform/core/internal/service"
)

type Server struct {
	httpServer *http.Server
	port       int
}

func New(cfg *config.ServerConfig, store db.Store, k8sClient *k8s.Client) *Server {
	authSvc := service.NewAuthService(store)

	registry := api.Services{
		Auth: authSvc,
	}

	apiHandler := api.NewHandler(k8sClient, store, cfg.InternalSecret, registry)

	router := apiHandler.Routes()

	addr := fmt.Sprintf(":%d", cfg.Port)
	httpServer := &http.Server{
		Addr:    addr,
		Handler: h2c.NewHandler(router, &http2.Server{}),
	}

	return &Server{
		httpServer: httpServer,
		port:       cfg.Port,
	}
}

func (s *Server) Run() error {
	return s.httpServer.ListenAndServe()
}

func (s *Server) Shutdown(ctx context.Context) error {
	return s.httpServer.Shutdown(ctx)
}
