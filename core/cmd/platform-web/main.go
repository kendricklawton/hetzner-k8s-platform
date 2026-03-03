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
	"github.com/kendricklawton/project-platform/gen/go/platform/v1/platformv1connect"
)

func main() {
	// 1. Load configuration
	cfg, err := config.LoadWeb()
	if err != nil {
		log.Fatalf("web config error: %v", err)
	}

	// 2. Initialize ConnectRPC clients pointing to the Core API
	apiClient := http.DefaultClient
	userClient := platformv1connect.NewUserServiceClient(apiClient, cfg.APIURL)
	teamClient := platformv1connect.NewTeamServiceClient(apiClient, cfg.APIURL)

	// 3. Mount the Web BFF Handler — no direct DB access, all data via Core API
	webHandler := web.NewHandler(
		cfg.APIURL,
		cfg.WebBaseURL,
		cfg.InternalSecret,
		cfg.WorkOSAPIKey,
		cfg.WorkOSClientID,
		cfg.WorkOSRedirectURI,
		userClient,
		teamClient,
	)

	// 4. Build the http.Server so we can shut it down gracefully
	addr := fmt.Sprintf(":%d", cfg.Port)
	srv := &http.Server{
		Addr:    addr,
		Handler: webHandler.Routes(),
	}

	// 5. Run in a goroutine so main can block on the signal channel
	go func() {
		log.Printf("🌐 Platform Web Server starting on http://localhost%s", addr)
		log.Printf("🔗 Connected to Core API at %s", cfg.APIURL)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("web server crashed: %v", err)
		}
	}()

	// 6. Block until Ctrl+C or SIGTERM
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt, syscall.SIGTERM)
	<-quit
	log.Println("🛑 Shutting down web server gracefully...")

	// 7. Give in-flight requests up to 10 s to finish
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Fatalf("web server forced to shutdown: %v", err)
	}

	log.Println("✅ Web server exited cleanly")
}
