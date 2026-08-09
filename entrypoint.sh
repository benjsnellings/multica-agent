#!/usr/bin/env bash
set -euo pipefail

# Permanent configuration / auth failures exit 78 so a restart loop is obvious
# in the logs rather than silently retrying forever.
readonly EX_CONFIG=78

# All persistent state (Multica creds, Claude/Cursor/Pi auth, npm cache) in /data.
export HOME=/data
export XDG_CONFIG_HOME=/data/.config
export XDG_DATA_HOME=/data/.local/share
export XDG_CACHE_HOME=/data/.cache
# Claude Code blocks bypassPermissions as root unless it knows it is sandboxed
# (see anthropics/claude-code#9184).
export IS_SANDBOX=1
export PATH="/data/bin:/data/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

mkdir -p "${XDG_CONFIG_HOME}" "${XDG_DATA_HOME}" "${XDG_CACHE_HOME}" \
  /data/.multica /data/.claude /data/.pi/agent /data/.npm \
  /data/bin /data/.local/bin /workspace

log() {
  local level="$1"; shift
  echo "[multica-agent] ${level}: $*"
}

die_config() {
  log error "$*"
  exit "${EX_CONFIG}"
}

SERVER_URL="${MULTICA_SERVER_URL:-https://api.multica.ai}"
APP_URL="${MULTICA_APP_URL:-https://multica.ai}"
DEVICE_NAME="${MULTICA_DEVICE_NAME:-$(hostname)}"
RUNTIME_NAME="${MULTICA_RUNTIME_NAME:-}"
WORKSPACE_ID="${MULTICA_WORKSPACE_ID:-}"
MAX_TASKS="${MULTICA_MAX_CONCURRENT_TASKS:-2}"
TOKEN="${MULTICA_TOKEN:-}"

export MULTICA_DAEMON_DEVICE_NAME="${DEVICE_NAME}"
export MULTICA_DAEMON_MAX_CONCURRENT_TASKS="${MAX_TASKS}"
if [[ -n "${RUNTIME_NAME}" ]]; then
  export MULTICA_AGENT_RUNTIME_NAME="${RUNTIME_NAME}"
fi

configure_provider_auth() {
  # Claude Code: API key bills Console/API usage, OAuth token uses the Pro/Max
  # subscription. The API key wins if both are set, so drop it when the OAuth
  # token is supplied.
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN || true
    log info "CLAUDE_CODE_OAUTH_TOKEN set for Claude Code (Pro/Max subscription)"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    log info "ANTHROPIC_API_KEY set for Claude Code (API / Console billing)"
  else
    log info "No Claude credentials in env — using existing /data/.claude login if present"
  fi

  if [[ -n "${CURSOR_API_KEY:-}" ]]; then
    log info "CURSOR_API_KEY set for Cursor Agent (plan auth)"
  else
    log info "No CURSOR_API_KEY — Cursor Agent will not authenticate until set"
  fi

  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    local model="${OPENROUTER_MODEL:-anthropic/claude-sonnet-4}"
    mkdir -p /data/.pi/agent
    jq -n --arg key "${OPENROUTER_API_KEY}" \
      '{openrouter: {type: "api_key", key: $key}}' > /data/.pi/agent/auth.json
    jq -n --arg model "${model}" \
      '{defaultProvider: "openrouter", defaultModel: $model}' > /data/.pi/agent/settings.json
    chmod 600 /data/.pi/agent/auth.json
    log info "Pi configured for OpenRouter (model=${model})"
  else
    log info "No OPENROUTER_API_KEY — Pi OpenRouter auth not configured"
  fi
}

write_agent_context() {
  cat >/data/AGENT_CONTEXT.md <<EOF
# Multica agent container

Standalone Multica daemon with Claude Code, Cursor Agent, and Pi CLIs.
No Home Assistant mounts — this container is agent runtimes only.

| Path | Access | Purpose |
|------|--------|---------|
| \`/workspace\` | read-write | Agent workdirs / repos (\`local_directory\` target) |
| \`/data\` | read-write | Daemon credentials + CLI state |

## Runtimes

- \`claude\` — Claude Code
- \`cursor-agent\` — Cursor Agent CLI
- \`pi\` — Pi coding agent (OpenRouter)

CLIs auto-update ${TOOL_UPDATE_BOOT_DELAY_SECONDS:-30}s after start and every
\`${TOOL_UPDATE_INTERVAL_SECONDS:-21600}\` seconds thereafter.
EOF
}

configure_provider_auth
write_agent_context

command -v multica >/dev/null || die_config "multica CLI missing from image"

for tool in claude cursor-agent pi; do
  if command -v "${tool}" >/dev/null; then
    log info "runtime tool present: ${tool} ($(${tool} --version 2>/dev/null | head -1 || echo ok))"
  else
    log warning "runtime tool missing: ${tool}"
  fi
done

log info "Configuring Multica CLI (server=${SERVER_URL})"
if [[ ! -f /data/.multica/config.json ]]; then
  printf '%s\n' '{}' > /data/.multica/config.json
fi

tmp="$(mktemp)"
jq \
  --arg server_url "${SERVER_URL}" \
  --arg app_url "${APP_URL}" \
  --arg device_name "${DEVICE_NAME}" \
  --argjson max_tasks "${MAX_TASKS}" \
  '.server_url = $server_url
   | .app_url = $app_url
   | .device_name = $device_name
   | .max_concurrent_tasks = $max_tasks' \
  /data/.multica/config.json >"${tmp}"
mv "${tmp}" /data/.multica/config.json

if [[ -n "${RUNTIME_NAME}" ]]; then
  tmp="$(mktemp)"
  jq --arg name "${RUNTIME_NAME}" '.runtime_name = $name' /data/.multica/config.json >"${tmp}"
  mv "${tmp}" /data/.multica/config.json
fi

if [[ -n "${WORKSPACE_ID}" ]]; then
  tmp="$(mktemp)"
  jq --arg id "${WORKSPACE_ID}" '.workspace_id = $id' /data/.multica/config.json >"${tmp}"
  mv "${tmp}" /data/.multica/config.json
fi

if [[ -n "${TOKEN}" ]]; then
  log info "Authenticating with Multica personal access token from env"
  multica login --token "${TOKEN}" \
    || die_config "multica login failed — check MULTICA_TOKEN"
elif multica auth status >/dev/null 2>&1; then
  log info "Using existing Multica credentials stored in /data"
else
  die_config "No Multica credentials. Set MULTICA_TOKEN (Settings → API Tokens)."
fi

if [[ -n "${WORKSPACE_ID}" ]]; then
  multica workspace switch "${WORKSPACE_ID}" >/dev/null 2>&1 \
    || log warning "Could not switch workspace to ${WORKSPACE_ID}"
fi

# Background CLI updater (the HA add-on runs this as an s6 longrun).
if [[ "${TOOL_UPDATES:-true}" == "true" ]]; then
  (
    sleep "${TOOL_UPDATE_BOOT_DELAY_SECONDS:-30}"
    while true; do
      /usr/local/bin/update-agent-tools || true
      sleep "${TOOL_UPDATE_INTERVAL_SECONDS:-21600}"
    done
  ) &
  log info "tool-updater started (interval=${TOOL_UPDATE_INTERVAL_SECONDS:-21600}s)"
else
  log info "tool-updater disabled (TOOL_UPDATES=false)"
fi

DAEMON_ARGS=(
  daemon start --foreground
  --device-name "${DEVICE_NAME}"
  --max-concurrent-tasks "${MAX_TASKS}"
)
if [[ -n "${RUNTIME_NAME}" ]]; then
  DAEMON_ARGS+=(--runtime-name "${RUNTIME_NAME}")
fi

log info "Starting Multica daemon (device=${DEVICE_NAME}, workspace=/workspace)"
exec multica "${DAEMON_ARGS[@]}"
