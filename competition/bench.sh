#!/usr/bin/env bash
# Benchmarks the scheme.cr demo-todo app (competition/scheme/demo-todo/app.scm)
# against its Sinatra+ERB+Sequel+SQLite twin (competition/ruby/demo-todo/app.rb)
# using wrk. Run from the repo root: ./competition/bench.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME_PORT=4571
RUBY_PORT=4570
CRYSTAL_PORT=4572
RACKET_PORT=4573
DURATION=${DURATION:-8s}
THREADS=${THREADS:-4}
CONNS=${CONNS:-32}

cleanup() {
  pkill -f "bin/creme .*demo-todo/app.scm" 2>/dev/null || true
  pkill -f "tail -f /dev/null" 2>/dev/null || true
  pkill -f "ruby app.rb" 2>/dev/null || true
  pkill -f "crystal/demo-todo/bin/app" 2>/dev/null || true
  pkill -f "racket .*demo-todo/app.rkt" 2>/dev/null || true
}
trap cleanup EXIT

wait_for_port() {
  local port=$1
  for _ in $(seq 1 50); do
    if curl -s -o /dev/null "http://127.0.0.1:${port}/" -H "Accept: text/html"; then
      return 0
    fi
    sleep 0.1
  done
  echo "Server on port ${port} never came up" >&2
  exit 1
}

run_wrk() {
  local label=$1 url=$2 accept=$3
  echo "### ${label}"
  wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" -H "Accept: ${accept}" "${url}"
  echo
}

echo "== Starting scheme.cr (bin/creme) app on :${SCHEME_PORT} =="
cd "$REPO_ROOT"
tail -f /dev/null | PORT=$SCHEME_PORT ./bin/creme competition/scheme/demo-todo/app.scm --lib modules > /tmp/bench-scheme.log 2>&1 &
disown
wait_for_port "$SCHEME_PORT"

echo
echo "############ scheme.cr / bin/creme ############"
run_wrk "GET / (text/html)" "http://127.0.0.1:${SCHEME_PORT}/" "text/html"
run_wrk "GET / (application/json)" "http://127.0.0.1:${SCHEME_PORT}/" "application/json"

cleanup
sleep 1

echo "== Starting Ruby (Sinatra+ERB+Sequel+SQLite) app on :${RUBY_PORT} =="
cd "$REPO_ROOT/competition/ruby/demo-todo"
(PORT=$RUBY_PORT bundle exec ruby app.rb > /tmp/bench-ruby.log 2>&1 &)
wait_for_port "$RUBY_PORT"

echo
echo "############ Ruby / Sinatra+ERB+Sequel+SQLite ############"
run_wrk "GET / (text/html)" "http://127.0.0.1:${RUBY_PORT}/" "text/html"
run_wrk "GET / (application/json)" "http://127.0.0.1:${RUBY_PORT}/" "application/json"

cleanup
sleep 1

echo "== Building and starting Crystal (Kemal+Granite+ECR+SQLite) app on :${CRYSTAL_PORT} =="
cd "$REPO_ROOT/competition/crystal/demo-todo"
mkdir -p bin
if [ ! -x bin/app ] || [ src/app.cr -nt bin/app ]; then
  shards build --release
fi
PORT=$CRYSTAL_PORT ./bin/app > /tmp/bench-crystal.log 2>&1 &
disown
wait_for_port "$CRYSTAL_PORT"

echo
echo "############ Crystal / Kemal+Granite+ECR+SQLite ############"
run_wrk "GET / (text/html)" "http://127.0.0.1:${CRYSTAL_PORT}/" "text/html"
run_wrk "GET / (application/json)" "http://127.0.0.1:${CRYSTAL_PORT}/" "application/json"

cleanup
sleep 1

echo "== Starting Racket (web-server/dispatch+db+SQLite) app on :${RACKET_PORT} =="
cd "$REPO_ROOT/competition/racket/demo-todo"
PORT=$RACKET_PORT racket app.rkt > /tmp/bench-racket.log 2>&1 &
disown
wait_for_port "$RACKET_PORT"

echo
echo "############ Racket / web-server+db+SQLite ############"
run_wrk "GET / (text/html)" "http://127.0.0.1:${RACKET_PORT}/" "text/html"
run_wrk "GET / (application/json)" "http://127.0.0.1:${RACKET_PORT}/" "application/json"

cleanup
