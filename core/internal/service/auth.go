package service

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/kendricklawton/project-platform/core/internal/db"
)

type AuthService struct {
	Store db.Store
}

func NewAuthService(store db.Store) *AuthService {
	return &AuthService{Store: store}
}

type UserProfile struct {
	Email     string
	FirstName string
	LastName  string
}

func (s *AuthService) ProvisionUser(ctx context.Context, p UserProfile) (*db.User, error) {
	user, err := s.Store.GetUserByEmail(ctx, p.Email)
	if err == nil {
		return &user, nil
	}

	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}

	userID, err := uuid.NewV7()
	if err != nil {
		return nil, fmt.Errorf("generating user ID: %w", err)
	}
	workspaceID, err := uuid.NewV7()
	if err != nil {
		return nil, fmt.Errorf("generating workspace ID: %w", err)
	}
	fullName := fmt.Sprintf("%s %s", p.FirstName, p.LastName)

	_, err = s.Store.OnboardUserWithWorkspace(ctx, db.OnboardUserWithWorkspaceParams{
		ID:     userID,
		Email:  p.Email,
		Name:   fullName,
		ID_2:   workspaceID,
		Name_2: "My Workspace",
		Slug:   fmt.Sprintf("%s-workspace", generateSlug(fullName)),
	})
	if err != nil {
		// Two concurrent logins for the same email can both pass the GetUserByEmail
		// check before either inserts. If we lost the race, fetch the winner's record.
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			existing, fetchErr := s.Store.GetUserByEmail(ctx, p.Email)
			if fetchErr != nil {
				return nil, fmt.Errorf("re-fetching user after concurrent insert: %w", fetchErr)
			}
			return &existing, nil
		}
		return nil, fmt.Errorf("onboarding user: %w", err)
	}

	return &db.User{ID: userID, Email: p.Email, Name: fullName}, nil
}

func (s *AuthService) DeleteUserWithCleanup(ctx context.Context, userID uuid.UUID) error {
	return s.Store.ExecTx(ctx, func(q *db.Queries) error {
		if err := q.DeleteOrphanedWorkspaces(ctx, userID); err != nil {
			return fmt.Errorf("deleting orphaned workspaces: %w", err)
		}
		return q.DeleteUser(ctx, userID)
	})
}

func generateSlug(name string) string {
	reg := regexp.MustCompile("[^a-z0-9]+")
	return strings.Trim(reg.ReplaceAllString(strings.ToLower(name), "-"), "-")
}
