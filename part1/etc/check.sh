#!/usr/bin/env sh
# Build, start two nodes, and demonstrate every operation locally and forwarded.
set -eu
cd "$(dirname "$0")/.."
make build
LOGS=$(mktemp -d)
P1= P2=
cleanup() {
  [ -z "$P1" ] || kill "$P1" 2>/dev/null || true
  [ -z "$P2" ] || kill "$P2" 2>/dev/null || true
}
trap cleanup EXIT
./bin/server -id n1 -http 127.0.0.1:18080 -grpc 127.0.0.1:15051 >"$LOGS/n1.log" 2>&1 & P1=$!
./bin/server -id n2 -http 127.0.0.1:18081 -grpc 127.0.0.1:15052 -target 127.0.0.1:15051 >"$LOGS/n2.log" 2>&1 & P2=$!

for port in 18080 18081; do
  ready=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl --max-time 1 -fsS "http://127.0.0.1:$port/openapi.yaml" >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.3
  done
  if [ "$ready" != 1 ]; then cat "$LOGS/n1.log" "$LOGS/n2.log"; exit 1; fi
  sh ./etc/demo.sh "http://127.0.0.1:$port"
  curl --max-time 5 -fsS "http://127.0.0.1:$port/v1/players/alice" | grep -q 'from n1'
done
echo 'ALL CHECKS PASSED: direct and forwarded replies identify n1'
