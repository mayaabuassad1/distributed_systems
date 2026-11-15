#set page(paper: "a4", margin: 2.5cm)
#set text(font: "New Computer Modern", size: 11pt)
#set par(justify: true, leading: 0.65em)
#set heading(numbering: "1.")

// --- Page 1: Title Page ---
#align(center)[
  #v(3cm)
  #text(size: 18pt, weight: "bold")[Distributed Systems (236351) — Practical Assignment]
  #v(0.5em)
  #text(size: 14pt)[Part I Report: Party Leaderboard Service]
  #v(2em)
  Or Vaxman (325403871) & Partner Name (ID) \
]

#pagebreak()

// --- Page 2: Start of Report Content ---
= Overview and Architecture

Our service implements the leaderboard of a single-player game with a party mode: a player can compete solo, or a party of several players can complete a round together. Every incoming REST request is handled by a thin HTTP translation layer implementing the Go server interface generated from `openapi.yaml`, which maps the operation to one or more RPCs issued to a gRPC service generated from our `.proto` specification.

In Part I, the gRPC service is stateless and returns well-formed dummy responses tagged with the answering server's `node_id`. In subsequent milestones, this dummy gRPC backend will be replaced first by a local deterministic state machine (Part II) and then by a Multi-Paxos replicated log (Part III). To support request forwarding across nodes, a server instance can be launched with the `-target` flag pointing to another server's gRPC address, causing its HTTP layer to forward all incoming client requests to that target server over gRPC.

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
      [$arrow.r$ #text(size: 8pt)[REST/HTTP]],
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
  caption: [Request forwarding across two servers when Server 1 is configured with `-target` pointing to Server 2.],
) <fig-forwarding>