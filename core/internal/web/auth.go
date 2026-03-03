package web

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/workos/workos-go/v6/pkg/usermanagement"
)

const (
	// SessionCookieName holds the authenticated user's UUID.
	// HttpOnly — never exposed to JavaScript.
	SessionCookieName = "platform_session"

	// nameCookieName holds the user's display name for server-side rendering.
	// HttpOnly — read by Go on each request, not by JS.
	nameCookieName = "platform_name"

	// slugCookieName holds the user's team/account slug (e.g. "k-henry-team").
	// Used to build slug-scoped URLs like /{slug}/services.
	slugCookieName = "platform_slug"

	// stateCookieName is the short-lived CSRF state cookie set during login.
	stateCookieName = "auth_state"

	// workosSessionCookieName holds the WorkOS session ID (the `sid` JWT claim).
	// Used on logout to revoke the WorkOS SSO session so the user is fully
	// signed out of the identity provider (e.g. Google) and not auto-logged back in.
	workosSessionCookieName = "platform_workos_sid"
)

// sessionKey is the context key used to pass the user UUID through middleware.
type sessionKey string

const tokenKey sessionKey = "auth_token"

// GetTokenFromContext safely extracts the user UUID from the request context.
// It is set by RequireAuth after validating the session cookie.
func GetTokenFromContext(ctx context.Context) (string, bool) {
	token, ok := ctx.Value(tokenKey).(string)
	return token, ok
}

// GetDisplayName reads the stored display name cookie for server-side rendering.
// Returns an empty string if the user is not authenticated.
func GetDisplayName(r *http.Request) string {
	cookie, err := r.Cookie(nameCookieName)
	if err != nil || cookie.Value == "" {
		return ""
	}
	return cookie.Value
}

// GetSlug reads the team/account slug cookie for slug-scoped URL routing.
// Returns an empty string if the user is not authenticated.
func GetSlug(r *http.Request) string {
	cookie, err := r.Cookie(slugCookieName)
	if err != nil || cookie.Value == "" {
		return ""
	}
	return cookie.Value
}

// RequireAuth protects routes by checking for a valid session cookie.
//
// HTMX challenge: a plain 302 redirect causes HTMX to load the login page
// HTML fragment into #main-content instead of navigating the full page.
// Fix: detect HX-Request header and respond with HX-Redirect instead,
// which instructs HTMX to perform a full browser navigation.
func (h *Handler) RequireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie(SessionCookieName)
		if err != nil || cookie.Value == "" {
			if r.Header.Get("HX-Request") == "true" {
				w.Header().Set("HX-Redirect", "/auth/login")
				w.WriteHeader(http.StatusOK)
				return
			}
			http.Redirect(w, r, "/auth/login", http.StatusFound)
			return
		}
		ctx := context.WithValue(r.Context(), tokenKey, cookie.Value)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// AuthLogin generates a CSRF state, stores it in a short-lived cookie,
// then redirects the browser to WorkOS AuthKit.
//
// Must be a full page navigation — the login link in layout.templ intentionally
// uses a plain <a href="/auth/login"> with no hx-* attributes.
func (h *Handler) AuthLogin(w http.ResponseWriter, r *http.Request) {
	state, err := generateState()
	if err != nil {
		http.Error(w, "Failed to initialize login", http.StatusInternalServerError)
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     stateCookieName,
		Value:    state,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   300, // 5 minutes — enough for the OAuth round-trip
	})

	usermanagement.SetAPIKey(h.WorkOSAPIKey)
	authURL, err := usermanagement.GetAuthorizationURL(usermanagement.GetAuthorizationURLOpts{
		ClientID:    h.WorkOSClientID,
		RedirectURI: h.WorkOSRedirectURI,
		Provider:    "authkit",
		State:       state,
	})
	if err != nil {
		http.Error(w, "Failed to generate auth URL", http.StatusInternalServerError)
		return
	}

	http.Redirect(w, r, authURL.String(), http.StatusFound)
}

// AuthCallback handles the return redirect from WorkOS.
// Verifies CSRF state, exchanges the authorization code for a user profile,
// provisions the user in the database, then sets the session cookies.
func (h *Handler) AuthCallback(w http.ResponseWriter, r *http.Request) {
	code := r.URL.Query().Get("code")
	returnedState := r.URL.Query().Get("state")

	// Verify CSRF state before doing anything
	stateCookie, err := r.Cookie(stateCookieName)
	if err != nil || returnedState == "" || stateCookie.Value != returnedState {
		http.Error(w, "Invalid or expired authentication state", http.StatusUnauthorized)
		return
	}
	// Clear state cookie immediately after verification
	http.SetCookie(w, &http.Cookie{Name: stateCookieName, Value: "", Path: "/", MaxAge: -1})

	// Exchange the authorization code for a WorkOS user profile
	usermanagement.SetAPIKey(h.WorkOSAPIKey)
	authResp, err := usermanagement.AuthenticateWithCode(r.Context(), usermanagement.AuthenticateWithCodeOpts{
		ClientID: h.WorkOSClientID,
		Code:     code,
	})
	if err != nil {
		log.Printf("WorkOS AuthenticateWithCode error: %v", err)
		http.Error(w, "Authentication failed", http.StatusInternalServerError)
		return
	}

	// Provision the user via the Core API (the only layer with DB access)
	userID, userName, err := h.provisionUserViaAPI(r.Context(), authResp.User.Email, authResp.User.FirstName, authResp.User.LastName)
	if err != nil {
		log.Printf("provisionUserViaAPI error: %v", err)
		http.Error(w, "Failed to provision user account", http.StatusInternalServerError)
		return
	}

	exp := time.Now().Add(7 * 24 * time.Hour)

	// Session cookie — HttpOnly, stores the user UUID for auth
	http.SetCookie(w, &http.Cookie{
		Name:     SessionCookieName,
		Value:    userID,
		Path:     "/",
		HttpOnly: true,
		Secure:   false, // Set true in production (HTTPS)
		SameSite: http.SameSiteLaxMode,
		Expires:  exp,
	})

	// Display name cookie — HttpOnly, read server-side for rendering the header
	http.SetCookie(w, &http.Cookie{
		Name:     nameCookieName,
		Value:    userName,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Expires:  exp,
	})

	// Slug cookie — HttpOnly, used to build slug-scoped URLs (e.g. /k-henry-team/services).
	// TODO: derive from the database once team provisioning is wired up.
	http.SetCookie(w, &http.Cookie{
		Name:     slugCookieName,
		Value:    "k-henry-team",
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Expires:  exp,
	})

	// WorkOS session ID — extracted from the access token's `sid` claim.
	// Stored so AuthLogout can revoke the WorkOS SSO session and prevent
	// the identity provider (e.g. Google) from auto-logging the user back in.
	if sid, err := extractSIDFromJWT(authResp.AccessToken); err == nil && sid != "" {
		http.SetCookie(w, &http.Cookie{
			Name:     workosSessionCookieName,
			Value:    sid,
			Path:     "/",
			HttpOnly: true,
			SameSite: http.SameSiteLaxMode,
			Expires:  exp,
		})
	} else if err != nil {
		log.Printf("AuthCallback: could not extract WorkOS session ID: %v", err)
	}

	http.Redirect(w, r, "/k-henry-team", http.StatusFound)
}

// AuthLogout clears all session cookies and redirects to the WorkOS logout URL,
// which revokes the SSO session (e.g. Google) and then redirects back to the
// home page. Without this, the identity provider would auto-log the user back
// in immediately when they click Login again.
func (h *Handler) AuthLogout(w http.ResponseWriter, r *http.Request) {
	log.Printf("AuthLogout: clearing session cookies for request from %s", r.RemoteAddr)

	past := time.Unix(0, 0)

	// Delete all session cookies. MaxAge=-1 → Max-Age=0; Expires=epoch is
	// belt-and-suspenders for browsers that don't honour Max-Age.
	for _, name := range []string{SessionCookieName, nameCookieName, slugCookieName, workosSessionCookieName, stateCookieName} {
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

	log.Printf("AuthLogout: cookies cleared")

	// If we have a WorkOS session ID, redirect through WorkOS's logout endpoint
	// to revoke the SSO session. WorkOS will redirect back to BaseURL when done.
	sidCookie, err := r.Cookie(workosSessionCookieName)
	if err == nil && sidCookie.Value != "" {
		usermanagement.SetAPIKey(h.WorkOSAPIKey)
		logoutURL, err := usermanagement.GetLogoutURL(usermanagement.GetLogoutURLOpts{
			SessionID: sidCookie.Value,
			ReturnTo:  h.BaseURL,
		})
		if err == nil {
			log.Printf("AuthLogout: redirecting to WorkOS logout URL")
			http.Redirect(w, r, logoutURL.String(), http.StatusSeeOther)
			return
		}
		log.Printf("AuthLogout: failed to build WorkOS logout URL: %v", err)
	}

	// Fallback: WorkOS session ID unavailable, redirect home directly.
	log.Printf("AuthLogout: no WorkOS session found, redirecting home")
	http.Redirect(w, r, h.BaseURL, http.StatusSeeOther)
}

// extractSIDFromJWT decodes the payload of a JWT (without verifying the
// signature) and returns the `sid` claim, which WorkOS uses as the session ID.
func extractSIDFromJWT(token string) (string, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", fmt.Errorf("malformed JWT: expected 3 parts, got %d", len(parts))
	}
	// JWT uses base64url encoding with no padding
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", fmt.Errorf("decode JWT payload: %w", err)
	}
	var claims struct {
		SID string `json:"sid"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return "", fmt.Errorf("unmarshal JWT claims: %w", err)
	}
	return claims.SID, nil
}

// provisionUserViaAPI calls POST /v1/auth/provision on the Core API.
// Returns the user's ID and display name.
func (h *Handler) provisionUserViaAPI(ctx context.Context, email, firstName, lastName string) (string, string, error) {
	body, err := json.Marshal(map[string]string{
		"email":      email,
		"first_name": firstName,
		"last_name":  lastName,
	})
	if err != nil {
		return "", "", fmt.Errorf("marshal provision request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.APIURL+"/v1/auth/provision", bytes.NewReader(body))
	if err != nil {
		return "", "", fmt.Errorf("create provision request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Internal-Secret", h.InternalSecret)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("provision request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("provision returned %d", resp.StatusCode)
	}

	var result struct {
		ID    string `json:"id"`
		Name  string `json:"name"`
		Email string `json:"email"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", "", fmt.Errorf("decode provision response: %w", err)
	}

	return result.ID, result.Name, nil
}

// generateState returns a cryptographically random hex string for CSRF protection.
func generateState() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generating state: %w", err)
	}
	return hex.EncodeToString(b), nil
}
