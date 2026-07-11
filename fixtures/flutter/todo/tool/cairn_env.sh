#!/usr/bin/env bash
# Shared constants for the Cairn "local live" harness (W5). Sourced by the
# other tool/cairn_*.sh scripts — not meant to be run directly.
#
# "Local live" stands in for a real Supabase project (W0b is
# operator-blocked): real cairn-server + real docker Postgres + real HS256
# JWTs signed with the dev secret below. Same code paths a Supabase-JWKS
# deploy exercises (auth -> tenant-scoped reads -> tenant-enforced
# write-back), just HS256 instead of RS256/ES256 (auth.rs routes on the JWT's
# `alg` header, so this is a legitimate substitution, not a shortcut around
# the auth layer).

set -euo pipefail

# Repo root, resolved from this script's location (fixtures/flutter/todo/tool/).
CAIRN_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CAIRN_FIXTURE_DIR="$CAIRN_REPO_ROOT/fixtures/flutter/todo"
CAIRN_STATE_DIR="$CAIRN_FIXTURE_DIR/.cairn"

# Dev-only shared secret — never used against a real Postgres/Supabase
# project. Regenerated state lives entirely under .cairn/ (gitignored).
CAIRN_DEV_JWT_SECRET="cairn-todo-w5-local-live-dev-secret-do-not-use-in-production"

CAIRN_PG_URL="postgresql://cairn:cairn@localhost:5433/cairn"
CAIRN_PUBLICATION="cairn_pub_todo_w5"
CAIRN_SLOT="cairn_slot_todo_w5"
CAIRN_TENANT_COLUMN="user_id"
CAIRN_BIND="127.0.0.1:8810"
CAIRN_WS_PATH="/sync"
CAIRN_WS_URL="ws://$CAIRN_BIND$CAIRN_WS_PATH"
CAIRN_HEALTH_URL="http://$CAIRN_BIND/healthz"

CAIRN_DEV_LOG="$CAIRN_STATE_DIR/cairn-dev.log"
CAIRN_DEV_PID_FILE="$CAIRN_STATE_DIR/cairn-dev.pid"
