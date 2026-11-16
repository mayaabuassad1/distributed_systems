// Package grpcsvc implements the KVStore gRPC service.
//
// STEP 4 — In Part I every RPC returns a DUMMY response: the goal is only to
// prove that the .proto compiles and that two processes can talk over gRPC.
// In Part II this type will apply operations to the state machine, and in
// Part III it will submit them to the replicated log.
package grpcsvc

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sort"
	"math"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	leaderboardv1 "github.com/your-team/kvs/gen/leaderboard/v1"
)

// Server implements leaderboardv1.LeaderboardServiceServer.
//
// Embedding UnimplementedLeaderboardServiceServer makes every RPC not written yet return
// codes.Unimplemented (HTTP 501 after translation): when you add RPCs for your
// own service, the project keeps compiling while you work through them.
type Server struct {
	leaderboardv1.UnimplementedLeaderboardServiceServer

	NodeID string // shown in dummy values, so you can see WHICH server answered
}

func New(nodeID string) *Server { return &Server{NodeID: nodeID} }

// dummyKeys is the pretend content of the store. The key "missing" never
// exists, so you can test the 404 path end to end.
var dummyPlayers = []struct{
	id   string
	name string
	score int64
}{	
	{id: "alice", name: "Alice", score: 100},
	{id: "bob", name: "Bob", score: 200},
	{id: "carol", name: "Carol", score: 300},
}

func (s *Server) dummyPlayer(id string, consistency leaderboardv1.Consistency) *leaderboardv1.Player {
	for _, dp := range dummyPlayers {
		if dp.id == id {
			return &leaderboardv1.Player{
				Id:    dp.id,
				Name:  fmt.Sprintf("%s (from %s, %s)", dp.name, s.NodeID, consistency),
				Score: dp.score,
			}
		}
	}
	return &leaderboardv1.Player{
		Id:    id,
		Name:  fmt.Sprintf("Dummy %s (from %s, %s)", id, s.NodeID, consistency),
		Score: 55,
	}
}


// ---------------------------------------------------------------------------
// The example service (a key-value store). Replace it with your own service.
// ---------------------------------------------------------------------------

func (s *Server) CreatePlayer(ctx context.Context, req *leaderboardv1.CreatePlayerRequest) (*leaderboardv1.CreatePlayerResponse, error) {
	// Check if the player already exists
	
	if req.GetId() == "" || req.GetName() == "" {
		return nil, status.Errorf(codes.InvalidArgument, "player ID %q and name %q are required", req.GetId(), req.GetName())
	}

	for _, player := range dummyPlayers {
		if player.id == req.GetId() {
			return nil, status.Errorf(codes.AlreadyExists, "player %q already exists", req.GetId())
		}
	}

	// Create a new player with the provided ID and name, and a default score of 0
	newPlayer := &leaderboardv1.Player{
		Id:    req.GetId(),
		Name:  fmt.Sprintf("%s (dummy from %s)", req.GetName(), s.NodeID),
		Score: 0,
	}


	return &leaderboardv1.CreatePlayerResponse{Player: newPlayer}, nil
}

// GetPlayers is server streaming: one GetPlayersResponse per entry, in sort order.
func (s *Server) GetPlayers(req *leaderboardv1.GetPlayersRequest, stream leaderboardv1.LeaderboardService_GetPlayersServer) error {
	if req.GetLimit() < 0 {
		return status.Errorf(codes.InvalidArgument, "limit %d must be non-negative", req.GetLimit())
	}
	var players []*leaderboardv1.Player
	switch sel := req.GetSelect().(type) {
	case *leaderboardv1.GetPlayersRequest_Id: // exactly one key: missing is an error
		if sel.Id == "" {
			return status.Errorf(codes.InvalidArgument, "key %q not found", sel.Id)
		}
		if sel.Id == "missing" {
			return status.Errorf(codes.NotFound, "key %q not found", sel.Id)
		}
		players = append(players, s.dummyPlayer(sel.Id, req.GetConsistency()))
	case *leaderboardv1.GetPlayersRequest_Ids: // several keys: missing ones are skipped
		seen := make(map[string]bool) // check for duplicates in the request
		for _, id := range sel.Ids.GetIds() {
			if id == "" || id == "missing" || seen[id] {
				continue
			}
			seen[id] = true
			players = append(players, s.dummyPlayer(id, req.GetConsistency()))
		}

	case nil: // no selector: every key
		for _, dp := range dummyPlayers {
			players = append(players, s.dummyPlayer(dp.id, req.GetConsistency()))
		}
	}

	// Sort by score descending, then by ID ascending. Limit the number of results if requested.
	sort.Slice(players, func(i, j int) bool {
		if players[i].Score != players[j].Score {
			return players[i].Score > players[j].Score
		}
		return players[i].Id < players[j].Id
	})
	if n := int(req.GetLimit()); n > 0 && n < len(players) {
		players = players[:n]
	}

	for _, player := range players {
		if err := stream.Send(&leaderboardv1.GetPlayersResponse{Player: player}); err != nil {
			return err
		}
	}
	return nil
}

// IncrementScores is client streaming: the client sends one IncrementScoresRequest per key and
// closes the stream; the server answers once, for the whole batch.
func (s *Server) IncrementScores(stream leaderboardv1.LeaderboardService_IncrementScoresServer) error {
	reqs, err := recvAll[leaderboardv1.IncrementScoresRequest](stream.Recv)
	if err != nil {
		return err
	}
	if len(reqs) == 0 {
		return status.Error(codes.InvalidArgument, "no score increment requests received")
	}
	const dummyScore int64 = 55 // pretend every key starts at 55, except "missing" which is new
	seen := make(map[string]bool) // check for duplicate IDs in the request
	// Check the whole batch before "applying" anything: all or nothing.
	
	for _, r := range reqs { // nothing is stored: compute the result and echo it
		id := r.GetId()
		delta := r.GetDelta()
		if id == "" {
			return status.Error(codes.InvalidArgument, "player ID cannot be empty")
		}
		if delta <= 0 {
			return status.Errorf(codes.InvalidArgument, "delta %d must be positive for player %q", delta, id)
		}
		if id == "missing" {
			return status.Errorf(codes.NotFound, "player %q not found", id)
		}
		if dummyScore > math.MaxInt64 - delta {
			return status.Errorf(codes.InvalidArgument, "score overflow for player %q: %d + %d exceeds max int64", id, dummyScore, delta)
		}
		if seen[id] {
			return status.Errorf(codes.InvalidArgument, "duplicate player ID %q in request", id)
		}
		seen[id] = true
	}

	out := &leaderboardv1.IncrementScoresResponse{}
	for _, r := range reqs {
		id := r.GetId()
		delta := r.GetDelta()
		newScore := dummyScore + delta
		out.Players = append(out.Players, &leaderboardv1.Player{
			Id:    id,
			Name:  fmt.Sprintf("Dummy %s (from %s)", id, s.NodeID),
			Score: newScore,
		})
	}

	return stream.SendAndClose(out)
}

// DeletePlayers is client streaming as well: one DeleteRequest per key.
func (s *Server) DeletePlayers(stream leaderboardv1.LeaderboardService_DeletePlayersServer) error {
	reqs, err := recvAll[leaderboardv1.DeletePlayersRequest](stream.Recv)
	if err != nil {
		return err
	}
	if len(reqs) == 0 {
		return status.Error(codes.InvalidArgument, "no delete targets received")
	}

	var deleted int32
	for _, r := range reqs {
		switch target := r.GetTarget().(type) {
		case *leaderboardv1.DeletePlayersRequest_Id:
			id := target.Id
			if id == "" {
				return status.Error(codes.InvalidArgument, "player ID cannot be empty")
			}
			if id == "missing" {
				continue // pretend it was already gone
			}
			deleted++
		case *leaderboardv1.DeletePlayersRequest_All:
			if !target.All {
				return status.Error(codes.InvalidArgument, "delete all must be true to delete all players")
			}
			deleted += int32(len(dummyPlayers)) // pretend we deleted all players
		default:
			return status.Error(codes.InvalidArgument, "invalid delete target")
		}
	}
	return stream.SendAndClose(&leaderboardv1.DeletePlayersResponse{Deleted: deleted, NodeId: s.NodeID})
}

// recvAll reads a client stream until the client closes it (io.EOF).
func recvAll[T any](recv func() (*T, error)) ([]*T, error) {
	var all []*T
	for {
		m, err := recv()
		if errors.Is(err, io.EOF) {
			return all, nil
		}
		if err != nil {
			return nil, err
		}
		all = append(all, m)
	}
}
