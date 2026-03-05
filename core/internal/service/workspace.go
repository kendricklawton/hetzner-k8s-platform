package service

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/kendricklawton/project-platform/core/internal/authctx"
	"github.com/kendricklawton/project-platform/core/internal/db"
	pb "github.com/kendricklawton/project-platform/gen/go/platform/v1"
)

type WorkspaceServer struct {
	Store db.Store
}

func NewWorkspaceServer(store db.Store) *WorkspaceServer {
	return &WorkspaceServer{Store: store}
}

func (s *WorkspaceServer) CreateWorkspace(
	ctx context.Context,
	req *connect.Request[pb.CreateWorkspaceRequest],
) (*connect.Response[pb.CreateWorkspaceResponse], error) {

	workspaceID, err := uuid.NewV7()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	creatorID, ok := authctx.GetUserID(ctx)
	if !ok {
		return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("missing user identity"))
	}

	workspace, err := s.Store.CreateWorkspaceWithOwner(ctx, db.CreateWorkspaceWithOwnerParams{
		ID:     workspaceID,
		Name:   req.Msg.Name,
		Slug:   req.Msg.Slug,
		UserID: creatorID,
	})

	if err != nil {
		if strings.Contains(err.Error(), "23505") {
			return nil, connect.NewError(connect.CodeAlreadyExists, fmt.Errorf("workspace slug '%s' is already taken", req.Msg.Slug))
		}
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("failed to create workspace: %w", err))
	}

	return connect.NewResponse(&pb.CreateWorkspaceResponse{
		Id:   workspace.ID.String(),
		Name: workspace.Name,
		Slug: workspace.Slug,
	}), nil
}
