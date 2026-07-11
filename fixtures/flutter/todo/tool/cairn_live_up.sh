#!/usr/bin/env bash
# Bring up the Cairn "local live" harness for the todo fixture (W5):
#   1. docker Postgres up (idempotent — reuses an already-running container).
#   2. create the `todos` table (idempotent — CREATE TABLE IF NOT EXISTS).
#   3. `cairn init` — real CLI, creates/reconciles the publication, writes
#      cairn.toml + .env under .cairn/ (idempotent re-run per its own doc).
#   4. append the dev JWT secret to .env (cairn init only ever writes
#      CAIRN_PG_URL there) and pin the server bind to a port that won't
#      collide with the zero-setup default (8800) or the SDK's own
#      integration test (8801).
#   5. `cairn dev` — real CLI, backgrounded; waits for /healthz.
#
# Safe to re-run: each step no-ops or reconciles rather than erroring. Prints
# the ws:// URL + two ready-to-use dev JWTs (user-a / user-b) on success.
#
# Requires: docker, cargo, openssl. First run compiles cairn-cli + cairn-server
# from scratch (see the timing dry-run in docs/QUICKSTART.md).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./cairn_env.sh

echo "== 1/5: docker Postgres =="
docker compose -f "$CAIRN_REPO_ROOT/docker/docker-compose.yml" up -d postgres
for i in $(seq 1 60); do
  if docker exec cairn-postgres pg_isready -U cairn -d cairn >/dev/null 2>&1; then
    echo "  postgres ready after ${i}s"
    break
  fi
  sleep 1
done
docker exec cairn-postgres pg_isready -U cairn -d cairn >/dev/null 2>&1 \
  || { echo "postgres did not become ready in 60s"; exit 1; }

echo "== 2/5: todos table =="
docker exec -i cairn-postgres psql -U cairn -d cairn -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS todos (
  id text primary key,
  user_id text not null,
  title text not null,
  done boolean not null default false,
  created_at timestamptz not null default now()
);
SQL
echo "  ✓ todos table present"

mkdir -p "$CAIRN_STATE_DIR"

echo "== 3/5: cairn init =="
# cairn-cli's `init`/`dev`/`doctor` all resolve cairn.toml/.env against the
# PROCESS cwd (crates/cairn-cli/src/main.rs), so this must run from .cairn/.
(cd "$CAIRN_STATE_DIR" && cargo run --quiet --manifest-path "$CAIRN_REPO_ROOT/Cargo.toml" -p cairn-cli -- init \
  --db-url "$CAIRN_PG_URL" \
  --tables todos \
  --write-tables todos \
  --tenant-column "$CAIRN_TENANT_COLUMN" \
  --publication "$CAIRN_PUBLICATION" \
  --slot "$CAIRN_SLOT")

echo "== 4/5: dev JWT secret + bind port =="
if ! grep -q '^CAIRN_SUPABASE_JWT_SECRET=' "$CAIRN_STATE_DIR/.env" 2>/dev/null; then
  echo "CAIRN_SUPABASE_JWT_SECRET=$CAIRN_DEV_JWT_SECRET" >> "$CAIRN_STATE_DIR/.env"
fi
# Pin the port `cairn init` doesn't expose a flag for (server.bind always
# defaults to 0.0.0.0:8800 — see crates/cairn-cli/src/commands/init.rs).
sed -i.bak "s#^bind = \".*\"#bind = \"$CAIRN_BIND\"#" "$CAIRN_STATE_DIR/cairn.toml"
rm -f "$CAIRN_STATE_DIR/cairn.toml.bak"
echo "  ✓ $CAIRN_STATE_DIR/cairn.toml + .env ready"

echo "== 5/5: cairn dev =="
if [ -f "$CAIRN_DEV_PID_FILE" ] && kill -0 "$(cat "$CAIRN_DEV_PID_FILE")" 2>/dev/null; then
  echo "  already running (pid $(cat "$CAIRN_DEV_PID_FILE"))"
else
  (cd "$CAIRN_STATE_DIR" && nohup cargo run --quiet --manifest-path "$CAIRN_REPO_ROOT/Cargo.toml" -p cairn-cli -- dev \
    > "$CAIRN_DEV_LOG" 2>&1 &
    echo $! > "$CAIRN_DEV_PID_FILE")
  echo "  started (pid $(cat "$CAIRN_DEV_PID_FILE")); waiting for $CAIRN_HEALTH_URL ..."
  ready=""
  for i in $(seq 1 180); do
    if curl -sf -o /dev/null "$CAIRN_HEALTH_URL"; then
      ready=1
      echo "  healthy after ${i}s"
      break
    fi
    sleep 1
  done
  if [ -z "$ready" ]; then
    echo "cairn-server did not become healthy in 180s — see $CAIRN_DEV_LOG"
    exit 1
  fi
fi

echo
echo "ws URL:  $CAIRN_WS_URL"
echo "user-a token: $(./mint_jwt.sh user-a)"
echo "user-b token: $(./mint_jwt.sh user-b)"
echo
echo "tool/cairn_live_down.sh to stop."
