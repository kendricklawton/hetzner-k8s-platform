package web

import (
	"log"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/kendricklawton/project-platform/core/internal/web/ui/components"
	"github.com/kendricklawton/project-platform/core/internal/web/ui/pages"
	"github.com/workos/workos-go/v6/pkg/usermanagement"
)

// Handler is the Backend-For-Frontend (BFF) controller.
type Handler struct {
	APIURL               string
	BaseURL              string
	InternalSecret       string
	WorkOSAPIKey         string
	WorkOSClientID       string
	WorkOSRedirectURI    string
	WorkOSCLIRedirectURI string
}

// NewHandler creates a new Web Handler with all required dependencies.
func NewHandler(
	apiURL string,
	baseURL string,
	internalSecret string,
	workOSAPIKey string,
	workOSClientID string,
	workOSRedirectURI string,
	workOSCLIRedirectURI string,
) *Handler {
	return &Handler{
		APIURL:               apiURL,
		BaseURL:              baseURL,
		InternalSecret:       internalSecret,
		WorkOSAPIKey:         workOSAPIKey,
		WorkOSClientID:       workOSClientID,
		WorkOSRedirectURI:    workOSRedirectURI,
		WorkOSCLIRedirectURI: workOSCLIRedirectURI,
	}
}

// isMainContentSwap reports whether the request is an HTMX partial swap targeting #main-content.
func (h *Handler) isMainContentSwap(r *http.Request) bool {
	return r.Header.Get("HX-Request") == "true" && r.Header.Get("HX-Target") == "main-content"
}

// isDashboardSwap reports whether the request is an HTMX partial swap targeting #dashboard-content.
func (h *Handler) isDashboardSwap(r *http.Request) bool {
	return r.Header.Get("HX-Request") == "true" && r.Header.Get("HX-Target") == "dashboard-content"
}

// dashboardAuth validates auth and returns userName; redirects and returns "" on failure.
func (h *Handler) dashboardAuth(w http.ResponseWriter, r *http.Request) string {
	_, ok := GetTokenFromContext(r.Context())
	if !ok {
		http.Redirect(w, r, "/auth/login", http.StatusFound)
		return ""
	}
	return GetDisplayName(r)
}

// dashboardSlug validates auth and the URL slug against the user's slug cookie.
func (h *Handler) dashboardSlug(w http.ResponseWriter, r *http.Request) (userName, slug string) {
	userName = h.dashboardAuth(w, r)
	if userName == "" {
		return
	}
	slug = chi.URLParam(r, "slug")
	cookieSlug := GetSlug(r)
	if slug != cookieSlug {
		http.Redirect(w, r, "/"+cookieSlug, http.StatusFound)
		slug = ""
	}
	return
}

// RootRedirect sends authenticated users to their dashboard, others to login.
func (h *Handler) RootRedirect(w http.ResponseWriter, r *http.Request) {
	if _, err := r.Cookie(SessionCookieName); err == nil {
		if slug := GetSlug(r); slug != "" {
			http.Redirect(w, r, "/"+slug, http.StatusFound)
			return
		}
	}
	http.Redirect(w, r, "/auth/login", http.StatusFound)
}

// DashboardRedirect resolves /dashboard → /{slug} using the slug cookie.
func (h *Handler) DashboardRedirect(w http.ResponseWriter, r *http.Request) {
	slug := GetSlug(r)
	if slug == "" {
		http.Redirect(w, r, "/auth/login", http.StatusFound)
		return
	}
	http.Redirect(w, r, "/"+slug, http.StatusFound)
}

// Healthz handles the connection status check and returns the action button fragment.
func (h *Handler) Healthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	_, err := r.Cookie(SessionCookieName)
	isLoggedIn := err == nil

	actionURL := "/auth/login"
	buttonText := "INITIALIZE LOGIN SEQUENCE"
	if isLoggedIn {
		slug := GetSlug(r)
		if slug == "" {
			slug = "dashboard"
		}
		actionURL = "/" + slug
		buttonText = "ENTER SECURE CONSOLE"
	}

	component := components.HealthzStatus(actionURL, buttonText)
	if err := component.Render(r.Context(), w); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
	}
}

// Dashboard renders the projects overview. Requires RequireAuth middleware.
func (h *Handler) Dashboard(w http.ResponseWriter, r *http.Request) {
	userName, slug := h.dashboardSlug(w, r)
	if slug == "" {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if h.isMainContentSwap(r) {
		w.Header().Set("HX-Redirect", "/"+slug)
		return
	}
	if h.isDashboardSwap(r) {
		pages.DashboardContent(userName, slug).Render(r.Context(), w)
		return
	}
	pages.DashboardPage(userName, slug).Render(r.Context(), w)
}

// Project renders the project overview page.
func (h *Handler) Project(w http.ResponseWriter, r *http.Request) {
	userName, slug := h.dashboardSlug(w, r)
	if slug == "" {
		return
	}
	projectID := chi.URLParam(r, "projectID")
	projectName := projectID
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if h.isDashboardSwap(r) {
		pages.ProjectContent(slug, projectID, projectName).Render(r.Context(), w)
		return
	}
	pages.ProjectPage(userName, slug, projectID, projectName).Render(r.Context(), w)
}

// DashboardServices renders the services page.
func (h *Handler) DashboardServices(w http.ResponseWriter, r *http.Request) {
	userName, slug := h.dashboardSlug(w, r)
	if slug == "" {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if h.isDashboardSwap(r) {
		pages.DashboardServicesContent().Render(r.Context(), w)
		return
	}
	pages.DashboardServicesPage(userName, slug).Render(r.Context(), w)
}

// DashboardDeployments renders the deployments page.
func (h *Handler) DashboardDeployments(w http.ResponseWriter, r *http.Request) {
	userName, slug := h.dashboardSlug(w, r)
	if slug == "" {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if h.isDashboardSwap(r) {
		pages.DashboardDeploymentsContent().Render(r.Context(), w)
		return
	}
	pages.DashboardDeploymentsPage(userName, slug).Render(r.Context(), w)
}

// DashboardLogs renders the logs page.
func (h *Handler) DashboardLogs(w http.ResponseWriter, r *http.Request) {
	userName, slug := h.dashboardSlug(w, r)
	if slug == "" {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if h.isDashboardSwap(r) {
		pages.DashboardLogsContent().Render(r.Context(), w)
		return
	}
	pages.DashboardLogsPage(userName, slug).Render(r.Context(), w)
}

// DashboardSecrets renders the secrets page.
func (h *Handler) DashboardSecrets(w http.ResponseWriter, r *http.Request) {
	userName, slug := h.dashboardSlug(w, r)
	if slug == "" {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if h.isDashboardSwap(r) {
		pages.DashboardSecretsContent().Render(r.Context(), w)
		return
	}
	pages.DashboardSecretsPage(userName, slug).Render(r.Context(), w)
}

// DashboardDomains renders the domains page.
func (h *Handler) DashboardDomains(w http.ResponseWriter, r *http.Request) {
	userName, slug := h.dashboardSlug(w, r)
	if slug == "" {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if h.isDashboardSwap(r) {
		pages.DashboardDomainsContent().Render(r.Context(), w)
		return
	}
	pages.DashboardDomainsPage(userName, slug).Render(r.Context(), w)
}

// DashboardSettings renders the dashboard settings page.
func (h *Handler) DashboardSettings(w http.ResponseWriter, r *http.Request) {
	userName, slug := h.dashboardSlug(w, r)
	if slug == "" {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if h.isDashboardSwap(r) {
		pages.DashboardSettingsContent().Render(r.Context(), w)
		return
	}
	pages.DashboardSettingsPage(userName, slug).Render(r.Context(), w)
}

// DashboardObservability renders the observability page.
func (h *Handler) DashboardObservability(w http.ResponseWriter, r *http.Request) {
	userName, slug := h.dashboardSlug(w, r)
	if slug == "" {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if h.isDashboardSwap(r) {
		pages.DashboardObservabilityContent().Render(r.Context(), w)
		return
	}
	pages.DashboardObservabilityPage(userName, slug).Render(r.Context(), w)
}

// Account renders the account settings page. Requires RequireAuth middleware.
func (h *Handler) Account(w http.ResponseWriter, r *http.Request) {
	userName := GetDisplayName(r)
	email := GetEmail(r)
	slug := GetSlug(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if h.isDashboardSwap(r) {
		pages.AccountContent(userName, email, slug).Render(r.Context(), w)
		return
	}
	pages.AccountPage(userName, email, slug).Render(r.Context(), w)
}

// AccountDelete deletes the authenticated user's account, clears all cookies,
// revokes the WorkOS session, and redirects to the home page.
func (h *Handler) AccountDelete(w http.ResponseWriter, r *http.Request) {
	userID, ok := GetTokenFromContext(r.Context())
	if !ok || userID == "" {
		http.Redirect(w, r, "/auth/login", http.StatusFound)
		return
	}
	expected := GetEmail(r)
	if expected == "" || r.FormValue("confirm") != expected {
		http.Error(w, "Confirmation does not match your email address", http.StatusBadRequest)
		return
	}
	if err := h.deleteAccountViaAPI(r.Context(), userID); err != nil {
		log.Printf("AccountDelete error: %v", err)
		http.Error(w, "Failed to delete account", http.StatusInternalServerError)
		return
	}
	usermanagement.SetAPIKey(h.WorkOSAPIKey)
	if wosUID, err := r.Cookie(workosUserIDCookieName); err == nil && wosUID.Value != "" {
		if err := usermanagement.DeleteUser(r.Context(), usermanagement.DeleteUserOpts{User: wosUID.Value}); err != nil {
			log.Printf("AccountDelete: failed to delete WorkOS user %s: %v", wosUID.Value, err)
		}
	}
	past := time.Unix(0, 0)
	for _, name := range []string{SessionCookieName, nameCookieName, emailCookieName, workosUserIDCookieName, slugCookieName, workosSessionCookieName, stateCookieName} {
		http.SetCookie(w, &http.Cookie{
			Name:     name,
			Value:    "",
			Path:     "/",
			HttpOnly: true,
			SameSite: http.SameSiteLaxMode,
			MaxAge:   -1,
			Expires:  past,
		})
	}
	w.Header().Set("HX-Redirect", "/")
	w.WriteHeader(http.StatusOK)
}

// Settings renders the protected settings page. Requires RequireAuth middleware.
func (h *Handler) Settings(w http.ResponseWriter, r *http.Request) {
	userName := GetDisplayName(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if h.isMainContentSwap(r) {
		component := pages.SettingsContent()
		if err := component.Render(r.Context(), w); err != nil {
			http.Error(w, "render error", http.StatusInternalServerError)
		}
		return
	}

	component := pages.SettingsPage(userName)
	if err := component.Render(r.Context(), w); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
	}
}
