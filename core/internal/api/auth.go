package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/kendricklawton/project-platform/core/internal/service"
)

type contextKey string

const userIDKey contextKey = "user_id"

// requireAuth validates authentication and injects the UserID into the context.
func (h *handler) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		if !strings.HasPrefix(authHeader, "Bearer ") {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		userID, err := uuid.Parse(strings.TrimPrefix(authHeader, "Bearer "))
		if err != nil {
			http.Error(w, "Invalid token format", http.StatusUnauthorized)
			return
		}

		// Inject the authenticated UUID into the request context
		ctx := context.WithValue(r.Context(), userIDKey, userID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// requireInternal guards endpoints only callable by trusted internal services.
// The caller must present the shared PLATFORM_INTERNAL_SECRET in X-Internal-Secret.
func (h *handler) requireInternal(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Internal-Secret") != h.InternalSecret {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type provisionRequest struct {
	Email     string `json:"email"`
	FirstName string `json:"first_name"`
	LastName  string `json:"last_name"`
}

type provisionResponse struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
	Slug  string `json:"slug"`
	Tier  string `json:"tier"`
}

// provisionUser is called by the web BFF after a successful WorkOS OAuth exchange.
// It gets or creates the user in the database and returns the user record.
func (h *handler) provisionUser(w http.ResponseWriter, r *http.Request) {
	var req provisionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}
	if req.Email == "" {
		http.Error(w, "email is required", http.StatusBadRequest)
		return
	}

	user, err := h.Services.Auth.ProvisionUser(r.Context(), service.UserProfile{
		Email:     req.Email,
		FirstName: req.FirstName,
		LastName:  req.LastName,
	})
	if err != nil {
		log.Printf("provisionUser error: %v", err)
		http.Error(w, "Failed to provision user", http.StatusInternalServerError)
		return
	}

	// Fetch the user's primary workspace slug (created atomically during onboarding).
	workspaces, _ := h.Store.GetWorkspacesForUser(r.Context(), user.ID)
	slug := ""
	for _, ws := range workspaces {
		if ws.Role == "owner" {
			slug = ws.Slug
			break
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(provisionResponse{
		ID:    user.ID.String(),
		Name:  user.Name,
		Email: user.Email,
		Slug:  slug,
		Tier:  user.Tier,
	})
}

type deleteAccountRequest struct {
	UserID string `json:"user_id"`
}

// deleteAccount is called by the web BFF to permanently delete a user and all
// their solely-owned workspaces. Protected by requireInternal.
func (h *handler) deleteAccount(w http.ResponseWriter, r *http.Request) {
	var req deleteAccountRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}
	userID, err := uuid.Parse(req.UserID)
	if err != nil {
		http.Error(w, "Invalid user_id", http.StatusBadRequest)
		return
	}
	if err := h.Services.Auth.DeleteUserWithCleanup(r.Context(), userID); err != nil {
		log.Printf("deleteAccount error: %v", err)
		http.Error(w, "Failed to delete account", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

