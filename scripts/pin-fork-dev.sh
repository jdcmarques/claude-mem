#!/usr/bin/env bash
#
# pin-fork-dev.sh — Run only this checkout's claude-mem on this machine.
#
# What it does:
#   1. npm install && npm run build in the repo
#   2. Mirror the repo into ~/.claude/plugins/marketplaces/thedotmack (optional)
#   3. Pin CLAUDE_MEM_WORKER_SCRIPT_PATH in ~/.claude-mem/.env
#   4. Set CLAUDE_MEM_WORKER_PORT=37777 (and 127.0.0.1 host) in settings.json
#   5. Reinstall Cursor hooks + MCP to absolute paths under this repo's plugin/
#   6. Start or restart the worker on that port
#   7. Verify /api/health workerPath matches the fork
#
# Usage:
#   ./scripts/pin-fork-dev.sh
#   ./scripts/pin-fork-dev.sh --cursor-target project
#   ./scripts/pin-fork-dev.sh --prune-cache --align-marketplace-remote
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$REPO_ROOT/plugin"
WORKER_SCRIPT="$PLUGIN_ROOT/scripts/worker-service.cjs"
ENV_FILE="${CLAUDE_MEM_ENV_FILE:-$HOME/.claude-mem/.env}"
CACHE_ROOT="$HOME/.claude/plugins/cache/thedotmack/claude-mem"
MARKETPLACE_ROOT="$HOME/.claude/plugins/marketplaces/thedotmack"
PIN_KEY="CLAUDE_MEM_WORKER_SCRIPT_PATH"
DEFAULT_WORKER_PORT="37777"
DEFAULT_WORKER_HOST="127.0.0.1"

CURSOR_TARGET="user"
DO_BUILD=1
DO_SYNC=1
DO_PRUNE_CACHE=0
DO_ALIGN_REMOTE=0
DO_RESTART=1
DRY_RUN=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  cat <<'EOF'

Options:
  --cursor-target user|project   Where to write hooks.json / mcp.json (default: user)
  --skip-build                   Skip npm install and npm run build
  --skip-sync                    Skip sync-marketplace (mirror to ~/.claude/.../thedotmack)
  --no-restart                   Do not restart the worker after pinning
  --prune-cache                  Remove ~/.claude/plugins/cache/thedotmack/claude-mem/*
                                 (upstream semver cache cannot override the pin)
  --align-marketplace-remote     Set marketplace git origin to this repo's origin URL
  --dry-run                      Print actions without changing anything
  -h, --help                     Show this help
EOF
}

log() { printf '[pin-fork] %s\n' "$*"; }
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] $*"
  else
    log "+ $*"
    "$@"
  fi
}

SETTINGS_FILE="${CLAUDE_MEM_DATA_DIR:-$HOME/.claude-mem}/settings.json"

read_settings_kv() {
  local key="$1" default="$2"
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    printf '%s' "$default"
    return 0
  fi
  python3 - "$SETTINGS_FILE" "$key" "$default" <<'PY' 2>/dev/null || printf '%s' "$default"
import json, sys
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    env = data.get("env", data) if isinstance(data, dict) else {}
    val = env.get(key) if isinstance(env, dict) else None
    if val is None and isinstance(data, dict):
        val = data.get(key)
    print(val if val not in (None, "") else default)
except Exception:
    print(default)
PY
}

resolve_worker_port() {
  if [[ -n "${CLAUDE_MEM_WORKER_PORT:-}" ]]; then
    printf '%s' "$CLAUDE_MEM_WORKER_PORT"
  else
    read_settings_kv CLAUDE_MEM_WORKER_PORT 37777
  fi
}

resolve_worker_host() {
  local host
  if [[ -n "${CLAUDE_MEM_WORKER_HOST:-}" ]]; then
    host="$CLAUDE_MEM_WORKER_HOST"
  else
    host="$(read_settings_kv CLAUDE_MEM_WORKER_HOST 127.0.0.1)"
  fi
  [[ "$host" == "localhost" ]] && host="127.0.0.1"
  printf '%s' "$host"
}

worker_is_healthy() {
  local port host url
  port="$(resolve_worker_port)"
  host="$(resolve_worker_host)"
  url="http://${host}:${port}/api/health"
  curl -sf --max-time 3 "$url" >/dev/null 2>&1
}

wait_for_worker_health() {
  local attempt
  for attempt in $(seq 1 45); do
    if worker_is_healthy; then
      return 0
    fi
    sleep 1
  done
  return 1
}

worker_cli_env() {
  env \
    CLAUDE_MEM_WORKER_SCRIPT_PATH="$WORKER_SCRIPT" \
    CLAUDE_MEM_WORKER_PORT="$(resolve_worker_port)" \
    CLAUDE_MEM_WORKER_HOST="$(read_settings_kv CLAUDE_MEM_WORKER_HOST "$DEFAULT_WORKER_HOST")" \
    "$@"
}

ensure_default_worker_port() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] set CLAUDE_MEM_WORKER_PORT=$DEFAULT_WORKER_PORT in $SETTINGS_FILE"
    return 0
  fi
  mkdir -p "$(dirname "$SETTINGS_FILE")"
  chmod 700 "$(dirname "$SETTINGS_FILE")" 2>/dev/null || true
  python3 - "$SETTINGS_FILE" "$DEFAULT_WORKER_PORT" "$DEFAULT_WORKER_HOST" <<'PY'
import json, os, sys

path, port, host = sys.argv[1], sys.argv[2], sys.argv[3]
updates = {
    "CLAUDE_MEM_WORKER_PORT": port,
    "CLAUDE_MEM_WORKER_HOST": host,
}

def is_record(value):
    return isinstance(value, dict)

try:
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
        if not is_record(doc):
            doc = {}
    else:
        doc = {}
except Exception:
    doc = {}

env = doc.get("env")
nested = is_record(env) and any(k.startswith("CLAUDE_MEM_") for k in env)
target = env if nested else doc
if not is_record(target):
    target = {}
    if nested:
        doc["env"] = target
    else:
        doc = target

for key, val in updates.items():
    target[key] = val

with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
PY
  log "Set worker port to $DEFAULT_WORKER_PORT in $SETTINGS_FILE"
}

start_worker() {
  ensure_default_worker_port

  if worker_is_healthy; then
    log "Worker already up on port $(resolve_worker_port) — restarting for fork bundle"
    if worker_cli_env bun "$WORKER_SCRIPT" restart; then
      wait_for_worker_health && return 0
    fi
    log "WARN: restart did not verify; trying fresh daemon boot"
  else
    log "Worker not reachable on port $(resolve_worker_port) — starting"
  fi

  worker_cli_env bun "$WORKER_SCRIPT" stop >/dev/null 2>&1 || true
  if worker_cli_env bun "$WORKER_SCRIPT" restart; then
    wait_for_worker_health && return 0
  fi

  log "Trying daemon boot (--daemon)"
  worker_cli_env bun "$WORKER_SCRIPT" --daemon
  if wait_for_worker_health; then
    return 0
  fi
  log "ERROR: worker did not become healthy on port $(resolve_worker_port)"
  log "       tail ~/.claude-mem/logs/claude-mem-$(date +%Y-%m-%d).log"
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cursor-target)
      CURSOR_TARGET="${2:?missing value for --cursor-target}"
      shift 2
      ;;
    --skip-build) DO_BUILD=0; shift ;;
    --skip-sync) DO_SYNC=0; shift ;;
    --no-restart) DO_RESTART=0; shift ;;
    --prune-cache) DO_PRUNE_CACHE=1; shift ;;
    --align-marketplace-remote) DO_ALIGN_REMOTE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$CURSOR_TARGET" != "user" && "$CURSOR_TARGET" != "project" ]]; then
  echo "Invalid --cursor-target: $CURSOR_TARGET (use user or project)" >&2
  exit 1
fi

export PLUGIN_ROOT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLAUDE_MEM_WORKER_SCRIPT_PATH="$WORKER_SCRIPT"

upsert_env_var() {
  local key="$1" value="$2" file="$3"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] set $key in $file"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  chmod 700 "$(dirname "$file")" 2>/dev/null || true
  if [[ ! -f "$file" ]]; then
    cat >"$file" <<'HEADER'
# claude-mem credentials
# This file stores keys and gateway settings for the claude-mem memory agent

HEADER
    chmod 600 "$file"
  fi
  local tmp
  tmp="$(mktemp)"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    # Portable in-place replace (BSD + GNU sed)
    sed "s|^${key}=.*|${key}=${value}|" "$file" >"$tmp"
  else
    cp "$file" "$tmp"
    printf '\n%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$file"
  chmod 600 "$file"
}

log "Repo: $REPO_ROOT"
log "Worker pin: $WORKER_SCRIPT"

if [[ "$DO_BUILD" -eq 1 ]]; then
  run npm install --prefix "$REPO_ROOT"
  run npm run build --prefix "$REPO_ROOT"
fi

if [[ ! -f "$WORKER_SCRIPT" ]]; then
  echo "Worker still missing after build: $WORKER_SCRIPT" >&2
  exit 1
fi

if [[ "$DO_SYNC" -eq 1 ]]; then
  run npm run sync-marketplace:force --prefix "$REPO_ROOT"
fi

if [[ "$DO_ALIGN_REMOTE" -eq 1 ]]; then
  origin_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$origin_url" ]]; then
    log "No git origin on repo — skipping --align-marketplace-remote"
  elif [[ -d "$MARKETPLACE_ROOT/.git" ]]; then
    run git -C "$MARKETPLACE_ROOT" remote set-url origin "$origin_url"
    log "Marketplace origin → $origin_url"
  else
    log "Marketplace is not a git checkout — skipping remote align"
  fi
fi

upsert_env_var "$PIN_KEY" "$WORKER_SCRIPT" "$ENV_FILE"
log "Updated $PIN_KEY in $ENV_FILE"

ensure_default_worker_port

if [[ "$DO_PRUNE_CACHE" -eq 1 ]]; then
  if [[ -d "$CACHE_ROOT" ]]; then
    run rm -rf "${CACHE_ROOT:?}"/*
    log "Pruned plugin cache under $CACHE_ROOT"
  else
    log "No cache dir at $CACHE_ROOT — nothing to prune"
  fi
fi

# Cursor hooks/MCP: bake absolute paths from PLUGIN_ROOT (see install-paths.ts).
run env PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  CLAUDE_MEM_WORKER_SCRIPT_PATH="$WORKER_SCRIPT" \
  CLAUDE_MEM_WORKER_PORT="$(resolve_worker_port)" \
  CLAUDE_MEM_WORKER_HOST="$(resolve_worker_host)" \
  bun "$WORKER_SCRIPT" cursor install "$CURSOR_TARGET"

if [[ "$DO_RESTART" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] start_worker"
  else
    start_worker
  fi
fi

verify_worker_path() {
  local port host url
  port="$(resolve_worker_port)"
  host="$(resolve_worker_host)"
  url="http://${host}:${port}/api/health"
  local body
  if ! body="$(curl -sf --max-time 5 "$url" 2>/dev/null)"; then
    log "WARN: Could not reach $url — start worker manually: bun $WORKER_SCRIPT start"
    return 1
  fi
  local reported
  reported="$(printf '%s' "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('workerPath',''))" 2>/dev/null || true)"
  if [[ -z "$reported" ]]; then
    log "WARN: health response had no workerPath"
    return 1
  fi
  local expected_real worker_real
  expected_real="$(cd "$(dirname "$WORKER_SCRIPT")" && pwd)/$(basename "$WORKER_SCRIPT")"
  worker_real="$(cd "$(dirname "$reported")" && pwd)/$(basename "$reported")" 2>/dev/null || worker_real="$reported"
  if [[ "$worker_real" == "$expected_real" ]]; then
    log "OK: workerPath matches fork ($reported)"
    return 0
  fi
  log "WARN: workerPath is $reported"
  log "     expected fork $expected_real"
  log "     Try: CLAUDE_MEM_WORKER_SCRIPT_PATH=$WORKER_SCRIPT bun $WORKER_SCRIPT restart"
  return 1
}

if [[ "$DRY_RUN" -eq 0 ]]; then
  verify_worker_path || true
  log ""
  log "Viewer: http://$(resolve_worker_host):$(resolve_worker_port)/"
  log "Done. Restart Cursor so hooks reload."
  log "Audit: grep worker-service ~/.cursor/hooks.json ~/.cursor/mcp.json 2>/dev/null || true"
fi
