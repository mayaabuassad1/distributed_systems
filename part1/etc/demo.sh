#!/usr/bin/env sh
# Exercise every leaderboard operation and show HTTP statuses and dummy replies.
# Usage: sh etc/demo.sh [base-url]
set -eu
B=${1:-http://localhost:8080}
BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT
J='Content-Type: application/json'
expect() {
  want=$1 method=$2 path=$3; shift 3
  got=$(curl --max-time 10 -sS -o "$BODY" -w '%{http_code}' -X "$method" "$B$path" "$@")
  printf '%s %-6s %s\n' "$got" "$method" "$path"
  cat "$BODY"; printf '\n'
  if [ "$got" != "$want" ]; then
    printf 'FAIL: expected %s\n' "$want" >&2; exit 1
  fi
}

expect 200 GET '/v1/players/alice'
expect 200 GET '/v1/players'
expect 200 GET '/v1/players?id=alice&id=carol&id=missing&limit=2'
expect 200 GET '/v1/players?id=missing'
expect 404 GET '/v1/players/missing'
expect 400 GET '/v1/players?limit=bad'
expect 400 GET '/v1/players?limit=-1'
expect 201 POST '/v1/players' -H "$J" -d '{"id":"new","name":"New Player"}'
expect 409 POST '/v1/players' -H "$J" -d '{"id":"alice","name":"Alice"}'
expect 400 POST '/v1/players' -H "$J" -d '{}'
expect 200 PATCH '/v1/players/alice' -H "$J" -d '{"increment":10}'
expect 200 PATCH '/v1/players' -H "$J" -d '{"updates":[{"id":"alice","increment":10},{"id":"bob","increment":20}]}'
expect 400 PATCH '/v1/players/alice' -H "$J" -d '{"increment":0}'
expect 404 PATCH '/v1/players/missing' -H "$J" -d '{"increment":10}'
expect 400 PATCH '/v1/players' -H "$J" -d '{"updates":[]}'
expect 400 PATCH '/v1/players' -H "$J" -d '{"updates":[{"id":"alice","increment":1},{"id":"alice","increment":2}]}'
expect 404 PATCH '/v1/players' -H "$J" -d '{"updates":[{"id":"alice","increment":1},{"id":"missing","increment":2}]}'
expect 204 DELETE '/v1/players/alice'
expect 204 DELETE '/v1/players/missing'
expect 204 DELETE '/v1/players'
printf 'All demo requests passed at %s\n' "$B"
