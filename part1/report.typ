#set page(paper: "a4", margin: 2.5cm)
#set text(font: "New Computer Modern", size: 11pt)
#set par(justify: true, leading: 0.65em)
#set heading(numbering: "1.")
#show table: set par(justify: false)

// --- Page 1: Title Page (rest of page left empty for feedback) ---
#align(center)[
  #v(3cm)
  #text(size: 18pt, weight: "bold")[Distributed Systems (236351) — Practical Assignment]
  #v(0.5em)
  #text(size: 14pt)[Part I Report: Party Leaderboard Service]
  #v(2em)
  Or Vaxman (325403871) & Maya abu assad (325226025) \
]

#pagebreak()

// --- Page 2+: Report Content ---
= Overview and Architecture

Our service implements the leaderboard of a single-player game with a party mode: a player can compete solo, or a party of several players can complete a round together. Every incoming REST request is handled by a thin HTTP translation layer implementing the Go server interface generated from `openapi.yaml`, which maps the operation to one or more RPCs issued to a gRPC service generated from our `.proto` specification.

In Part I, the gRPC service is stateless and returns well-formed dummy responses tagged with the answering server's `node_id`. To support request forwarding across nodes, a server instance can be launched with the `-target` flag pointing to another server's gRPC address, causing its HTTP layer to forward all incoming client requests to that target server over gRPC.

#figure(
  box(inset: 10pt, stroke: 0.5pt + luma(180), radius: 4pt)[
    #set align(center + horizon)
    #grid(
      columns: 7,
      gutter: 6pt,
      rect(inset: 8pt, radius: 4pt, fill: luma(245))[Client],
      [$arrow.r$],
      rect(inset: 8pt, radius: 4pt, fill: rgb("#e8f0fe"))[
        HTTP Handlers \
        #text(size: 8.5pt)[(`oapi-codegen`)]
      ],
      [$arrow.r$],
      rect(inset: 8pt, radius: 4pt, fill: rgb("#e6f4ea"))[gRPC Client],
      [$arrow.r$],
      rect(inset: 8pt, radius: 4pt, fill: rgb("#fef7e0"))[
        Dummy gRPC Service \
        #text(size: 8.5pt)[(returns `node_id`)]
      ],
    )
  ],
  kind: image,
  caption: [Single-server request flow in Part I.],
) <fig-single-server>

#figure(
  box(inset: 12pt, stroke: 0.5pt + luma(180), radius: 4pt)[
    #set align(center + horizon)
    #grid(
      columns: 3,
      row-gutter: 8pt,
      column-gutter: 8pt,
      // Row 1: Client -> Server 1
      rect(inset: 8pt, radius: 4pt, fill: luma(245))[Client],
      [$arrow.r$ #text(size: 8pt)[REST/JSON]],
      rect(inset: 8pt, radius: 4pt, stroke: (dash: "dashed", paint: rgb("#4285f4")), fill: rgb("#f8faff"))[
        *Server 1* \
        HTTP Handlers $arrow.r$ gRPC Client \
        #text(size: 8pt)[(`-target` = Server 2)]
      ],

      // Row 2: Vertical gRPC forwarding arrow under Server 1
      [],
      [],
      [#align(center)[$arrow.b$ #text(size: 8pt)[gRPC]]],

      // Row 3: Server 2
      [],
      [],
      rect(inset: 8pt, radius: 4pt, stroke: (dash: "dashed", paint: rgb("#fbbc04")), fill: rgb("#fffdf5"))[
        *Server 2* \
        Dummy gRPC Service \
        #text(size: 8pt)[(responds with Server 2 `node_id`)]
      ],
    )
  ],
  kind: image,
  caption: [Request forwarding across two servers when Server 1 is configured with `-target` pointing to Server 2.],
) <fig-forwarding>

== Code Organization

The implementation is split across five main files:
- `api/openapi.yaml` and `gen/rest/rest.gen.go`: the REST specification and generated `StrictServerInterface` types.
- `internal/httpapi/handlers.go`: the HTTP handlers that translate REST requests into gRPC calls and map gRPC status errors to HTTP responses in `httpStatusFromGRPC`.
- `proto/leaderboard/v1/leaderboard.proto` and `gen/leaderboard/v1/`: the internal gRPC service definition (`leaderboard.v1`) and generated Go stubs.
- `internal/grpcsvc/server.go`: the `LeaderboardService` gRPC server, request validation, and dummy responses (which tag `Player.name` with the answering `node_id`).
- `cmd/server/main.go`: CLI flag parsing (`-id`, `-http`, `-grpc`, `-target`, `-cors-origin`), gRPC client dialing (defaulting `-target` to the local `-grpc` port when unset), gRPC reflection setup, and HTTP/gRPC server startup (including `/openapi.yaml`, `/docs`, and `/editor`).

== Design Choices

We consolidated the seven REST operations into four gRPC RPCs (`CreatePlayer`, `GetPlayers`, `IncrementScores`, and `DeletePlayers`) and used gRPC streams for variable-length operations. Unifying single-player and multi-player operations under the same RPCs keeps the internal gRPC interface compact and avoids duplicating validation and sorting logic across separate endpoints, while streaming avoids large repeated protobuf message fields. `GetPlayers` streams ranked players back one by one, and `IncrementScores` and `DeletePlayers` read a client stream via `recvAll` and apply the batch only after the client closes the stream.

For `Server.IncrementScores`, we validate the entire batch in a first pass before computing any updated scores. If the stream is empty or any entry has an empty ID, a non-positive increment (`delta <= 0`), a duplicate player ID, an unknown ID, or an `int64` overflow, the RPC aborts with an error so partial updates cannot happen. We also kept two different ordering rules: `Server.GetPlayers` always sorts results by score descending (breaking ties by ID ascending) before applying `limit`, whereas `Server.IncrementScores` returns players in the exact order sent by the client so party callers can match results to their input list.

Finally, `httpapi.Handlers` is completely stateless and performs no domain validation of its own. Keeping all validation and dummy response logic behind the gRPC interface ensures that a server started with `-target` forwards requests identically to a standalone node without duplicating rules in the HTTP layer.

= Service Semantics

The service stores `Player` records, each with a unique non-empty `id` (`string`), a display `name` (`string`), and a non-negative `score` (`int64`, initialized to `0`).

- *`createPlayer` (`POST /v1/players`):* Registers a new player with score `0`. Fails with `409 Conflict` if `id` already exists, or `400 Bad Request` if `id` or `name` is empty.
- *`listPlayers` (`GET /v1/players`):* Returns all players, or only those matching the repeated `id` query parameter (skipping unknown IDs and deduplicating repeated IDs), sorted by `(score DESC, id ASC)` and optionally capped by `limit` (`0` or omitted means unlimited).
- *`getPlayer` (`GET /v1/players/{id}`):* Fetches a single player by ID, returning `404 Not Found` if the player does not exist.
- *`incrementPlayer` (`PATCH /v1/players/{id}`) & `incrementPlayers` (`PATCH /v1/players`):* Atomically adds a strictly positive integer (`increment >= 1`) to one or more existing players. Every ID in a batch must exist and appear once, and `score + increment` must not overflow `int64`.
- *`deletePlayer` (`DELETE /v1/players/{id}`):* Removes one player. This operation is idempotent and returns `204 No Content` even if the ID does not exist.
- *`clearLeaderboard` (`DELETE /v1/players`):* Removes all players when a game session ends. Idempotent, returning `204 No Content` even when empty.

*Consistency:* Read operations (`listPlayers`, `getPlayer`) default to `sequential` consistency and accept `consistency=linearizable` as an optional query parameter. All write and read-modify-write operations (`createPlayer`, `incrementPlayer`, `incrementPlayers`, `deletePlayer`, `clearLeaderboard`) are `linearizable`.

= RESTful API

All endpoints accept and return `application/json`, and error responses return RFC 9457 `application/problem+json` payloads (`Problem` with `type`, `title`, `status`, and `detail`).

#figure(
  table(
    columns: (auto, auto, auto, auto, auto),
    inset: 5pt,
    align: left + horizon,
    table.header(
      [*Operation*], [*Method & Path*], [*Parameters*], [*Body (Req / Resp)*], [*Status Codes*]
    ),
    [`createPlayer`], [`POST /v1/players`], [None], [`NewPlayer (id, name)` / `Player`], [`201`, `400`, `409`],
    [`listPlayers`], [`GET /v1/players`], [Query: `id` (repeated), `limit`, `consistency`], [None / `PlayerList (players)`], [`200`, `400`],
    [`getPlayer`], [`GET /v1/players/{id}`], [Path: `id`; Query: `consistency`], [None / `Player`], [`200`, `400`, `404`],
    [`incrementPlayer`], [`PATCH /v1/players/{id}`], [Path: `id`], [`ScoreIncrement (increment)` / `Player`], [`200`, `400`, `404`],
    [`incrementPlayers`], [`PATCH /v1/players`], [None], [`ScoreBatch (updates)` / `PlayerList`], [`200`, `400`, `404`],
    [`deletePlayer`], [`DELETE /v1/players/{id}`], [Path: `id`], [None / Empty], [`204`],
    [`clearLeaderboard`], [`DELETE /v1/players`], [None], [None / Empty], [`204`],
  ),
  caption: [External REST endpoints defined in `api/openapi.yaml`.],
) <fig-rest-api>

= Internal gRPC API

In `proto/leaderboard/v1/leaderboard.proto`, every RPC defines its own request and response message types (`CreatePlayerRequest`/`Response`, `GetPlayersRequest`/`Response`, `IncrementScoresRequest`/`Response`, `DeletePlayersRequest`/`Response`), and errors are returned via gRPC status codes rather than response fields.

#figure(
  table(
    columns: (auto, auto, auto, auto),
    inset: 5pt,
    align: left + horizon,
    table.header([*REST Operation*], [*gRPC RPC*], [*Type*], [*Notes*]),
    [`createPlayer`], [`CreatePlayer`], [Unary], [Creates player with `score = 0`],
    [`listPlayers`], [`GetPlayers`], [Server stream], [Maps repeated query `id` to `select.ids` (`PlayerIdList`), or leaves `select` unset for all; passes `limit` and `consistency`],
    [`getPlayer`], [`GetPlayers`], [Server stream], [Sets `select.id`; returns `NOT_FOUND` if missing],
    [`incrementPlayer`], [`IncrementScores`], [Client stream], [Streams 1 item (`id`, `delta = increment`) and unwraps `players[0]`],
    [`incrementPlayers`], [`IncrementScores`], [Client stream], [Streams $N$ items from `updates`; commits on `CloseAndRecv()`],
    [`deletePlayer`], [`DeletePlayers`], [Client stream], [Streams 1 item with `target.id`; ignores `deleted` count for HTTP `204`],
    [`clearLeaderboard`], [`DeletePlayers`], [Client stream], [Streams 1 item with `target.all = true`; ignores `deleted` count for HTTP `204`],
  ),
  caption: [Mapping between REST operations and `LeaderboardService` RPCs.],
) <fig-rest-grpc-map>

`httpStatusFromGRPC` in `internal/httpapi/handlers.go` translates gRPC status codes to HTTP responses:

#figure(
  table(
    columns: (auto, auto, auto),
    inset: 5pt,
    align: left + horizon,
    table.header([*gRPC Code*], [*HTTP Status*], [*When Used*]),
    [`codes.OK` (`nil`)], [`200` / `201` / `204`], [Successful read/update (`200`), create (`201`), or delete (`204`)],
    [`codes.InvalidArgument`], [`400 Bad Request`], [Empty fields or streams, `delta <= 0`, duplicate batch IDs, `int64` overflow, `limit < 0`, or `target.all = false`],
    [`codes.NotFound`], [`404 Not Found`], [Missing player in `getPlayer` (`select.id`) or `IncrementScores`],
    [`codes.AlreadyExists`], [`409 Conflict`], [Duplicate player ID in `createPlayer`],
    [`codes.Unimplemented`], [`501 Not Implemented`], [Unimplemented handler or RPC (`UnimplementedLeaderboardServiceServer`)],
    [`codes.Unavailable`], [`503 Service Unavailable`], [Target gRPC node cannot be reached (gRPC client error)],
    [`codes.DeadlineExceeded`], [`504 Gateway Timeout`], [Upstream gRPC call timed out (gRPC client error)],
  ),
  caption: [gRPC-to-HTTP error translation in `httpStatusFromGRPC`.],
) <fig-grpc-http-status>

= Limitations and Unimplemented Parts

Following the Part I specification, `internal/grpcsvc/server.go` does not store state across requests. Instead, it reads from a fixed `dummyPlayers` slice (`alice` with `100`, `bob` with `200`, `carol` with `300`), synthesizes other unknown IDs with a placeholder score of `55` (also used as the base score for `IncrementScores`), and simulates `404` and `409` error paths using sentinel IDs (`"missing"` and the existing dummy IDs). Persistent state and replication are not implemented in Part I. Similarly, while `GetPlayersRequest` forwards the `Consistency` enum from the HTTP query string to the gRPC server (and echoes it in the dummy player `name`), both `CONSISTENCY_SEQUENTIAL` and `CONSISTENCY_LINEARIZABLE` reads currently behave identically.