package web

import (
	"net/http"
	"strings"

	"github.com/kendricklawton/project-platform/core/internal/web/ui/components"
	"github.com/kendricklawton/project-platform/core/internal/web/ui/pages"
	"github.com/kendricklawton/project-platform/gen/go/platform/v1/platformv1connect"
)

// Handler is the Backend-For-Frontend (BFF) controller.
// It owns the WorkOS OAuth flow but delegates all DB operations to the Core API.
type Handler struct {
	APIURL            string
	BaseURL           string
	InternalSecret    string
	WorkOSAPIKey      string
	WorkOSClientID    string
	WorkOSRedirectURI string
	UserClient        platformv1connect.UserServiceClient
	TeamClient        platformv1connect.TeamServiceClient
}

// NewHandler creates a new Web Handler with all required dependencies.
func NewHandler(
	apiURL string,
	baseURL string,
	internalSecret string,
	workOSAPIKey string,
	workOSClientID string,
	workOSRedirectURI string,
	userClient platformv1connect.UserServiceClient,
	teamClient platformv1connect.TeamServiceClient,
) *Handler {
	return &Handler{
		APIURL:            apiURL,
		BaseURL:           baseURL,
		InternalSecret:    internalSecret,
		WorkOSAPIKey:      workOSAPIKey,
		WorkOSClientID:    workOSClientID,
		WorkOSRedirectURI: workOSRedirectURI,
		UserClient:        userClient,
		TeamClient:        teamClient,
	}
}

// isMainContentSwap reports whether the request is an HTMX partial swap targeting #main-content.
func (h *Handler) isMainContentSwap(r *http.Request) bool {
	return r.Header.Get("HX-Request") == "true" && r.Header.Get("HX-Target") == "main-content"
}

// Splash renders the home page.
func (h *Handler) Splash(w http.ResponseWriter, r *http.Request) {
	userName := GetDisplayName(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if h.isMainContentSwap(r) {
		component := pages.SplashContent("INITIALIZING PLATFORM...", userName)
		if err := component.Render(r.Context(), w); err != nil {
			http.Error(w, "render error", http.StatusInternalServerError)
		}
		return
	}

	component := pages.SplashPage("INITIALIZING PLATFORM...", userName)
	if err := component.Render(r.Context(), w); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
	}
}

// Changelog renders the changelog page.
func (h *Handler) Changelog(w http.ResponseWriter, r *http.Request) {
	userName := GetDisplayName(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if h.isMainContentSwap(r) {
		component := pages.ChangelogContent(userName)
		if err := component.Render(r.Context(), w); err != nil {
			http.Error(w, "render error", http.StatusInternalServerError)
		}
		return
	}

	component := pages.ChangelogPage(userName)
	if err := component.Render(r.Context(), w); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
	}
}

// About renders the about page.
func (h *Handler) About(w http.ResponseWriter, r *http.Request) {
	userName := GetDisplayName(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if h.isMainContentSwap(r) {
		component := pages.AboutContent(userName)
		if err := component.Render(r.Context(), w); err != nil {
			http.Error(w, "render error", http.StatusInternalServerError)
		}
		return
	}

	component := pages.AboutPage(userName)
	if err := component.Render(r.Context(), w); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
	}
}

// Pricing renders the pricing page.
func (h *Handler) Pricing(w http.ResponseWriter, r *http.Request) {
	userName := GetDisplayName(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if h.isMainContentSwap(r) {
		component := pages.PricingContent(userName)
		if err := component.Render(r.Context(), w); err != nil {
			http.Error(w, "render error", http.StatusInternalServerError)
		}
		return
	}

	component := pages.PricingPage(userName)
	if err := component.Render(r.Context(), w); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
	}
}

// Healthz handles the connection status check and returns the action button fragment.
func (h *Handler) Healthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	_, err := r.Cookie(SessionCookieName)
	isLoggedIn := err == nil

	actionURL := "/auth/login"
	buttonText := "INITIALIZE LOGIN SEQUENCE"
	if isLoggedIn {
		actionURL = "/dashboard"
		buttonText = "ENTER SECURE CONSOLE"
	}

	component := components.HealthzStatus(actionURL, buttonText)
	if err := component.Render(r.Context(), w); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
	}
}

// Docs renders a documentation page by slug.
func (h *Handler) Docs(w http.ResponseWriter, r *http.Request) {
	slug := strings.TrimPrefix(r.URL.Path, "/docs/")
	slug = strings.TrimSuffix(slug, "/")
	if slug == "" || slug == "docs" {
		http.Redirect(w, r, "/docs/getting-started/quickstart", http.StatusFound)
		return
	}

	content, err := renderDoc(slug)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	title := docTitle(slug)
	userName := GetDisplayName(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if h.isMainContentSwap(r) {
		component := pages.DocsContent(slug, title, content)
		if err := component.Render(r.Context(), w); err != nil {
			http.Error(w, "render error", http.StatusInternalServerError)
		}
		return
	}

	component := pages.DocsPage(slug, title, content, userName)
	if err := component.Render(r.Context(), w); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
	}
}

// Dashboard renders the protected dashboard. Requires RequireAuth middleware.
func (h *Handler) Dashboard(w http.ResponseWriter, r *http.Request) {
	_, ok := GetTokenFromContext(r.Context())
	if !ok {
		http.Redirect(w, r, "/auth/login", http.StatusFound)
		return
	}

	userName := GetDisplayName(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if h.isMainContentSwap(r) {
		component := pages.DashboardContent()
		if err := component.Render(r.Context(), w); err != nil {
			http.Error(w, "render error", http.StatusInternalServerError)
		}
		return
	}

	component := pages.DashboardPage(userName)
	if err := component.Render(r.Context(), w); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
	}
}

// Settings renders the protected settings page. Requires RequireAuth middleware.
func (h *Handler) Settings(w http.ResponseWriter, r *http.Request) {
	_, ok := GetTokenFromContext(r.Context())
	if !ok {
		http.Redirect(w, r, "/auth/login", http.StatusFound)
		return
	}

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
