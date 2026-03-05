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

	// slugCookieName holds the user's workspace slug (e.g. "acme-corp-workspace").
	// Used to build slug-scoped URLs like /{slug}/services.
	slugCookieName = "platform_slug"

	// stateCookieName is the short-lived CSRF state cookie set during login.
	stateCookieName = "auth_state"

	// workosSessionCookieName holds the WorkOS session ID (the `sid` JWT claim).
	// Used on logout to revoke the WorkOS SSO session so the user is fully
	// signed out of the identity provider (e.g. Google) and not auto-logged back in.
	workosSessionCookieName = "platform_workos_sid"

	// emailCookieName holds the user's email address for server-side rendering.
	// Used by AccountDelete to validate the confirmation input.
	// HttpOnly — read by Go only, not exposed to JavaScript.
	emailCookieName = "platform_email"

	// workosUserIDCookieName holds the WorkOS user ID (e.g. "user_01H...").
	// Used by AccountDelete to remove the user from WorkOS on account deletion.
	workosUserIDCookieName = "platform_workos_uid"

	// tierCookieName holds the user's billing tier ("free", "pro", "enterprise").
	// HttpOnly — read server-side to gate features like new workspace creation.
	tierCookieName = "platform_tier"
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

// GetSlug reads the workspace slug cookie for slug-scoped URL routing.
// Returns an empty string if the user is not authenticated.
func GetSlug(r *http.Request) string {
	cookie, err := r.Cookie(slugCookieName)
	if err != nil || cookie.Value == "" {
		return ""
	}
	return cookie.Value
}

// GetTier reads the billing tier cookie. Defaults to "free" if not set.
func GetTier(r *http.Request) string {
	cookie, err := r.Cookie(tierCookieName)
	if err != nil || cookie.Value == "" {
		return "free"
	}
	return cookie.Value
}

// GetEmail reads the stored email cookie for account confirmation flows.
// Returns an empty string if the user is not authenticated.
func GetEmail(r *http.Request) string {
	cookie, err := r.Cookie(emailCookieName)
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
	userID, userName, workspaceSlug, tier, err := h.provisionUserViaAPI(r.Context(), authResp.User.Email, authResp.User.FirstName, authResp.User.LastName)
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

	// Email cookie — HttpOnly, used for account deletion confirmation.
	http.SetCookie(w, &http.Cookie{
		Name:     emailCookieName,
		Value:    authResp.User.Email,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Expires:  exp,
	})

	// WorkOS user ID cookie — HttpOnly, used to delete the user from WorkOS on account deletion.
	http.SetCookie(w, &http.Cookie{
		Name:     workosUserIDCookieName,
		Value:    authResp.User.ID,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Expires:  exp,
	})

	// Slug cookie — HttpOnly, used to build slug-scoped URLs (e.g. /my-workspace/services).
	http.SetCookie(w, &http.Cookie{
		Name:     slugCookieName,
		Value:    workspaceSlug,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Expires:  exp,
	})

	// Tier cookie — HttpOnly, used server-side to gate plan-restricted features.
	http.SetCookie(w, &http.Cookie{
		Name:     tierCookieName,
		Value:    tier,
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

	if workspaceSlug == "" {
		http.Redirect(w, r, "/dashboard", http.StatusFound)
		return
	}
	http.Redirect(w, r, "/"+workspaceSlug, http.StatusFound)
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
// Returns the user's ID, display name, primary workspace slug, and billing tier.
func (h *Handler) provisionUserViaAPI(ctx context.Context, email, firstName, lastName string) (userID, userName, slug, tier string, err error) {
	body, marshalErr := json.Marshal(map[string]string{
		"email":      email,
		"first_name": firstName,
		"last_name":  lastName,
	})
	if marshalErr != nil {
		err = fmt.Errorf("marshal provision request: %w", marshalErr)
		return
	}

	req, reqErr := http.NewRequestWithContext(ctx, http.MethodPost, h.APIURL+"/v1/auth/provision", bytes.NewReader(body))
	if reqErr != nil {
		err = fmt.Errorf("create provision request: %w", reqErr)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Internal-Secret", h.InternalSecret)

	resp, doErr := http.DefaultClient.Do(req)
	if doErr != nil {
		err = fmt.Errorf("provision request failed: %w", doErr)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		err = fmt.Errorf("provision returned %d", resp.StatusCode)
		return
	}

	var result struct {
		ID    string `json:"id"`
		Name  string `json:"name"`
		Email string `json:"email"`
		Slug  string `json:"slug"`
		Tier  string `json:"tier"`
	}
	if decErr := json.NewDecoder(resp.Body).Decode(&result); decErr != nil {
		err = fmt.Errorf("decode provision response: %w", decErr)
		return
	}

	userID = result.ID
	userName = result.Name
	slug = result.Slug
	tier = result.Tier
	if tier == "" {
		tier = "free"
	}
	return
}

// deleteAccountViaAPI calls DELETE /v1/auth/account on the Core API.
func (h *Handler) deleteAccountViaAPI(ctx context.Context, userID string) error {
	body, err := json.Marshal(map[string]string{"user_id": userID})
	if err != nil {
		return fmt.Errorf("marshal delete request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, h.APIURL+"/v1/auth/account", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create delete request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Internal-Secret", h.InternalSecret)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("delete request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("delete account returned %d", resp.StatusCode)
	}
	return nil
}

// cliRedirectCookieName holds the CLI's local callback URI through the WorkOS round-trip.
// Short-lived (5 min), HttpOnly, cleared immediately after use.
const cliRedirectCookieName = "auth_cli_redirect"

// AuthCLILogin starts the browser-based OAuth flow for the CLI.
// The CLI passes its local callback URI as redirect_uri (must be http://localhost).
// We store it in a short-lived cookie, then redirect to WorkOS using the BFF's
// /auth/cli/callback as the registered redirect URI.
func (h *Handler) AuthCLILogin(w http.ResponseWriter, r *http.Request) {
	cliRedirectURI := r.URL.Query().Get("redirect_uri")
	if cliRedirectURI == "" || !strings.HasPrefix(cliRedirectURI, "http://localhost") {
		http.Error(w, "invalid redirect_uri: must be http://localhost", http.StatusBadRequest)
		return
	}

	state, err := generateState()
	if err != nil {
		http.Error(w, "failed to initialize login", http.StatusInternalServerError)
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     stateCookieName,
		Value:    state,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   300,
	})
	http.SetCookie(w, &http.Cookie{
		Name:     cliRedirectCookieName,
		Value:    cliRedirectURI,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   300,
	})

	usermanagement.SetAPIKey(h.WorkOSAPIKey)
	authURL, err := usermanagement.GetAuthorizationURL(usermanagement.GetAuthorizationURLOpts{
		ClientID:    h.WorkOSClientID,
		RedirectURI: h.WorkOSCLIRedirectURI,
		Provider:    "authkit",
		State:       state,
	})
	if err != nil {
		http.Error(w, "failed to generate auth URL", http.StatusInternalServerError)
		return
	}

	http.Redirect(w, r, authURL.String(), http.StatusFound)
}

// AuthCLICallback handles the WorkOS redirect for the CLI auth flow.
// Exchanges the code for a user profile, provisions the user, then redirects
// to the CLI's local callback server with the user token.
func (h *Handler) AuthCLICallback(w http.ResponseWriter, r *http.Request) {
	code := r.URL.Query().Get("code")
	returnedState := r.URL.Query().Get("state")

	stateCookie, err := r.Cookie(stateCookieName)
	if err != nil || returnedState == "" || stateCookie.Value != returnedState {
		http.Error(w, "invalid or expired authentication state", http.StatusUnauthorized)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: stateCookieName, Value: "", Path: "/", MaxAge: -1})

	cliRedirectCookie, err := r.Cookie(cliRedirectCookieName)
	if err != nil || cliRedirectCookie.Value == "" {
		http.Error(w, "missing CLI redirect URI", http.StatusBadRequest)
		return
	}
	cliRedirectURI := cliRedirectCookie.Value
	http.SetCookie(w, &http.Cookie{Name: cliRedirectCookieName, Value: "", Path: "/", MaxAge: -1})

	// Defense in depth: re-validate the stored redirect URI
	if !strings.HasPrefix(cliRedirectURI, "http://localhost") {
		http.Error(w, "invalid redirect URI", http.StatusBadRequest)
		return
	}

	usermanagement.SetAPIKey(h.WorkOSAPIKey)
	authResp, err := usermanagement.AuthenticateWithCode(r.Context(), usermanagement.AuthenticateWithCodeOpts{
		ClientID: h.WorkOSClientID,
		Code:     code,
	})
	if err != nil {
		log.Printf("AuthCLICallback: WorkOS error: %v", err)
		http.Error(w, "authentication failed", http.StatusInternalServerError)
		return
	}

	userID, _, _, _, err := h.provisionUserViaAPI(r.Context(), authResp.User.Email, authResp.User.FirstName, authResp.User.LastName)
	if err != nil {
		log.Printf("AuthCLICallback: provision error: %v", err)
		http.Error(w, "failed to provision user", http.StatusInternalServerError)
		return
	}

	http.Redirect(w, r, cliRedirectURI+"?token="+userID, http.StatusFound)
}

// generateState returns a cryptographically random hex string for CSRF protection.
func generateState() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generating state: %w", err)
	}
	return hex.EncodeToString(b), nil
}
