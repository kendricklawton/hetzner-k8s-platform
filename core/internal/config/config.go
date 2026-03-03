package config

import (
	"fmt"
	"os"
	"strconv"
)

type ServerConfig struct {
	Port           int
	Debug          bool
	DatabaseURL    string
	WorkOSAPIKey   string
	WorkOSClientID string
	InternalSecret string
}

func LoadServer() (*ServerConfig, error) {
	cfg := &ServerConfig{}
	var err error

	if cfg.Port, err = getEnvInt("PLATFORM_PORT", 8080); err != nil {
		return nil, err
	}

	if cfg.Debug, err = getEnvBool("PLATFORM_DEBUG", false); err != nil {
		return nil, err
	}

	if cfg.DatabaseURL, err = getEnvRequired("PLATFORM_DATABASE_URL"); err != nil {
		return nil, err
	}
	if cfg.WorkOSAPIKey, err = getEnvRequired("WORKOS_API_KEY"); err != nil {
		return nil, err
	}
	if cfg.WorkOSClientID, err = getEnvRequired("WORKOS_CLIENT_ID"); err != nil {
		return nil, err
	}
	if cfg.InternalSecret, err = getEnvRequired("PLATFORM_INTERNAL_SECRET"); err != nil {
		return nil, err
	}

	return cfg, nil
}

// WEB BFF CONFIGURATION (For platform-web)
type WebConfig struct {
	Port              int
	Debug             bool
	APIURL            string
	WebBaseURL        string
	InternalSecret    string
	WorkOSAPIKey      string
	WorkOSClientID    string
	WorkOSRedirectURI string
}

func LoadWeb() (*WebConfig, error) {
	cfg := &WebConfig{}
	var err error

	if cfg.Port, err = getEnvInt("PLATFORM_WEB_PORT", 3000); err != nil {
		return nil, err
	}
	if cfg.Debug, err = getEnvBool("PLATFORM_DEBUG", false); err != nil {
		return nil, err
	}

	cfg.APIURL = getEnv("PLATFORM_API_URL", "http://localhost:8080")
	cfg.WebBaseURL = getEnv("PLATFORM_WEB_BASE_URL", "http://localhost:3000")

	if cfg.InternalSecret, err = getEnvRequired("PLATFORM_INTERNAL_SECRET"); err != nil {
		return nil, err
	}
	if cfg.WorkOSAPIKey, err = getEnvRequired("WORKOS_API_KEY"); err != nil {
		return nil, err
	}
	if cfg.WorkOSClientID, err = getEnvRequired("WORKOS_CLIENT_ID"); err != nil {
		return nil, err
	}

	cfg.WorkOSRedirectURI = getEnv("WORKOS_WEB_REDIRECT_URI", "http://localhost:3000/auth/callback")

	return cfg, nil
}

// CLI CONFIGURATION (For platform-cli)
// CLIConfig holds the state for the developer's local CLI environment.
// The `mapstructure` tags allow Viper to easily unmarshal JSON/Env vars into this struct.
type CLIConfig struct {
	APIURL string `mapstructure:"api_url" json:"api_url"`
	Token  string `mapstructure:"token" json:"token"`
}

// LoadCLI provides a fallback manual loader, but in Cobra/Viper setups,
// you will typically use `viper.Unmarshal(&cfg)` to populate this struct.
func LoadCLI() (*CLIConfig, error) {
	cfg := &CLIConfig{}

	// Default to localhost for local development, but this will be overridden
	// by viper if `~/.platform/config.json` or `PLATFORM_API_URL` exists.
	cfg.APIURL = getEnv("PLATFORM_API_URL", "http://localhost:8080")
	cfg.Token = getEnv("PLATFORM_TOKEN", "")

	return cfg, nil
}

// HELPER FUNCTIONS
func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}

func getEnvRequired(key string) (string, error) {
	value, exists := os.LookupEnv(key)
	if !exists || value == "" {
		return "", fmt.Errorf("missing required environment variable: %s", key)
	}
	return value, nil
}

func getEnvInt(key string, fallback int) (int, error) {
	if value, exists := os.LookupEnv(key); exists && value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil {
			return 0, fmt.Errorf("invalid integer for %s: %s", key, value)
		}
		return parsed, nil
	}
	return fallback, nil
}

func getEnvBool(key string, fallback bool) (bool, error) {
	if value, exists := os.LookupEnv(key); exists && value != "" {
		parsed, err := strconv.ParseBool(value)
		if err != nil {
			return false, fmt.Errorf("invalid boolean for %s: %s", key, value)
		}
		return parsed, nil
	}
	return fallback, nil
}
