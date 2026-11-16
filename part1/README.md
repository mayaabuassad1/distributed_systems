# Game Leaderboard — Part I

A leaderboard for one game, with a REST API for clients and gRPC for internal
communication. Players have a unique ID, a name, and a nonnegative score. The API
supports reads, writes, and batch score increments.

Every REST operation issues an RPC. Part I returns **stateless dummy responses**;
creating, incrementing, deleting, or clearing does not change subsequent reads.

## Prerequisites and build

- Go >= 1.26
- GNU Make and a POSIX shell (Git Bash on Windows)
- Protobuf compiler (`protoc`)
- `curl` for the demonstration scripts
- Optional: `grpcurl` for direct gRPC requests; Docker for hosted API tools

Run from this directory (`part1` in the repository, or `src` in the submission):

```bash
# Install the generator versions recorded in go.mod; run once on a new machine.
go install tool
export PATH="$(go env GOPATH)/bin:$PATH"

# Regenerate REST and protobuf code, tidy dependencies, vet, and build.
make build
```

The executable is `bin/server`. Generated code is under `gen/` and is ignored by
Git. Do not edit generated files; regenerate after changing OpenAPI or protobuf.

## Run and demonstrate

In terminal 1:

```bash
make run
```

This starts node `n1` with HTTP on port 8080 and gRPC on port 50051.
Open http://localhost:8080/docs for Swagger UI or
http://localhost:8080/editor for Swagger Editor. These pages load UI assets from
a CDN and require browser internet access. The specification is served at
http://localhost:8080/openapi.yaml. Save editor changes back to `api/openapi.yaml`.

In terminal 2, from the same project directory:

```bash
sh etc/demo.sh
make run2
```

Node `n2` listens on HTTP 8081 and gRPC 50052; its REST handlers call `n1` over
gRPC. In terminal 3, demonstrate the same operations through `n2`:

```bash
sh etc/demo.sh http://localhost:8081
```

Player names contain `from n1`, showing which gRPC server answered even when the
HTTP request went to `n2`. Stop each manually started server with Ctrl+C.

For automatic verification:

```bash
make check
```

This builds the project, starts two temporary nodes, and checks 20 HTTP requests
against each node, covering all seven operations and error cases. It also checks
that replies through the second node identify `n1`. It uses HTTP ports 18080/18081
and gRPC ports 15051/15052, and stops its server processes on exit.

## REST API and RPC mapping

| Method | Path | Operation | Success | RPC |
| --- | --- | --- | --- | --- |
| GET | `/v1/players/{id}` | Read one player | 200 | `GetPlayers`, single ID |
| GET | `/v1/players` | Read selected players or all | 200 | `GetPlayers`, ID list or no selector |
| POST | `/v1/players` | Create a player with score zero | 201 | `CreatePlayer` |
| PATCH | `/v1/players/{id}` | Increment one score | 200 | `IncrementScores`, one request |
| PATCH | `/v1/players` | Increment several scores atomically | 200 | `IncrementScores`, streamed batch |
| DELETE | `/v1/players/{id}` | Remove one player | 204 | `DeletePlayers`, ID target |
| DELETE | `/v1/players` | Clear the leaderboard | 204 | `DeletePlayers`, all target |

List reads accept repeated `id` parameters, such as `?id=alice&id=bob`, and an
optional nonnegative `limit`. No IDs means all players; zero/absent limit means
unlimited. Results sort by score descending, breaking ties by ID ascending.

Both GET operations accept `consistency=sequential` (default) or
`consistency=linearizable`. The handler forwards the choice to gRPC, which echoes
it in the dummy player name. All writes are declared linearizable. These are
API declarations only: Part I does not enforce consistency guarantees.

POST body: `{"id":"new","name":"New Player"}`.

Single PATCH body: `{"increment":10}`.

Batch PATCH body:

```json
{"updates":[{"id":"alice","increment":10},{"id":"bob","increment":20}]}
```

Batch increments use one gRPC stream. The backend validates the complete batch
before replying; IDs must not repeat and increments must be positive without
overflowing int64. Results follow request order. Deletes are idempotent.

## Dummy responses

The full leaderboard contains Alice (`alice`, 100), Bob (`bob`, 200), and Carol
(`carol`, 300). The ID `missing` simulates an absent player: a single lookup or
increment returns 404, list lookups skip it, and deleting it succeeds.
Other requested IDs receive dummy players with score 55.

Creating one of the three predefined IDs returns 409; other IDs return a dummy
new player with score zero. Every increment returns `55 + increment`, regardless
of the read fixture score. Deletes acknowledge without changing anything.
These are placeholder results, not a stored state machine.

Errors use `application/problem+json`. Centralized gRPC-to-HTTP mapping:

| gRPC status | HTTP |
| --- | --- |
| `INVALID_ARGUMENT` | 400 |
| `NOT_FOUND` | 404 |
| `ALREADY_EXISTS` | 409 |
| `FAILED_PRECONDITION` | 412 |
| `UNIMPLEMENTED` | 501 |
| `UNAVAILABLE` | 503 |
| `DEADLINE_EXCEEDED` | 504 |
| Other errors | 500 |

## Inspect gRPC directly

With `n1` running:

```bash
grpcurl -plaintext localhost:50051 list
grpcurl -plaintext -d '{"id":"alice"}' localhost:50051 leaderboard.v1.LeaderboardService/GetPlayers
grpcurl -plaintext -d '{"id":"alice","delta":10}' localhost:50051 leaderboard.v1.LeaderboardService/IncrementScores
```

## Source layout

- `api/openapi.yaml`: REST contract.
- `api/oapi-codegen.yaml`: generated models, standard HTTP router and strict interface.
- `proto/leaderboard/v1/leaderboard.proto`: internal service and messages.
- `internal/grpcsvc/server.go`: dummy RPC implementations.
- `internal/httpapi/handlers.go`: REST-to-gRPC translation and error mapping.
- `cmd/server/main.go`: server wiring, forwarding, reflection and documentation routes.
- `etc/demo.sh`, `etc/check.sh`: demonstration and automatic verification.
- `report.typ`, `report.pdf`: report source and PDF draft.

`TUTORIAL.md` is the original course template walkthrough and still describes its
key-value example. Use this README for the implemented leaderboard.
