package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/kendricklawton/project-platform/core/internal/config"
	"github.com/kendricklawton/project-platform/core/internal/web"
)

func main() {
	cfg, err := config.LoadWeb()
	if err != nil {
		log.Fatalf("web config error: %v", err)
	}

	webHandler := web.NewHandler(
		cfg.APIURL,
		cfg.WebBaseURL,
		cfg.InternalSecret,
		cfg.WorkOSAPIKey,
		cfg.WorkOSClientID,
		cfg.WorkOSRedirectURI,
		cfg.WorkOSCLIRedirectURI,
	)

	addr := fmt.Sprintf(":%d", cfg.Port)
	srv := &http.Server{
		Addr:    addr,
		Handler: webHandler.Routes(),
	}

	go func() {
		log.Printf("Platform Web starting on http://localhost%s", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("web server crashed: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt, syscall.SIGTERM)
	<-quit
	log.Println("Shutting down web server...")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Fatalf("web server forced to shutdown: %v", err)
	}

	log.Println("Web server exited cleanly")
}
