# multica-agent — deployment runbook

Build a standalone Multica daemon image containing Claude Code, Cursor Agent,
and Pi; publish it to GHCR from a dedicated repo; run it as a service in the
existing Multica compose stack on the Docker VM.

**Machines involved**

| Step | Where you run it |
|---|---|
| 1 — credentials | Mac (needs a browser) |
| 2–3 — repo + image | Mac |
| 4–7 — deploy | Docker VM `192.168.1.131` (or Dockge web UI) |

---

## Step 1 — Gather credentials (Mac)

All four are set once in `.env` and read on every container start. There is no
interactive login at any point after this.

### 1a. Claude Code

```bash
claude setup-token
```

Opens a browser, prints a one-year OAuth token (`sk-ant-oat01-...`) to the
terminal. It is **not** saved anywhere — copy it now. Requires a Pro, Max,
Team, or Enterprise plan.

> Set **either** `CLAUDE_CODE_OAUTH_TOKEN` **or** `ANTHROPIC_API_KEY`, never
> both. The API key takes precedence when both are present, which causes
> confusing auth failures. The entrypoint drops the API key when the OAuth
> token is set, but leave the unused one blank anyway.

### 1b. Cursor

Generate a **User API key** from the Cursor dashboard — this is the one that
authorises the headless `cursor-agent` CLI. The dashboard panel has moved
recently, so follow the current doc:
<https://cursor.com/docs/cli/reference/authentication>

### 1c. Pi

An OpenRouter key from <https://openrouter.ai/keys>.

### 1d. Multica

A personal access token from **Settings → API Tokens** in your Multica
instance.

Park all four somewhere safe for Step 5.

---

## Step 2 — Create the GitHub repo (Mac)

Extract the provided tarball wherever you keep repos, then:

```bash
cd multica-agent
echo "=== tree ==="
find . -type f -not -path './.git/*' | sort
echo "=== init ==="
git init -b main
git add -A
git commit -m "Standalone Multica agent image (Claude Code, Cursor Agent, Pi)"
gh repo create benjsnellings/multica-agent --public --source=. --push
```

Without `gh`: create an empty repo in the web UI, then

```bash
git remote add origin git@github.com:benjsnellings/multica-agent.git
git push -u origin main
```

Watch the build:

```bash
gh run watch
```

The workflow builds, smoke-tests all four CLIs inside the image, asserts the
entrypoint exits 78 when given no credentials, then pushes
`ghcr.io/benjsnellings/multica-agent:latest` plus a short-SHA tag.

---

## Step 3 — Make the GHCR package public (Mac)

```bash
gh api -X PATCH /user/packages/container/multica-agent/visibility \
  -f visibility=public
echo "=== verify ==="
gh api /user/packages/container/multica-agent --jq '.visibility'
```

UI alternative: repo → Packages → `multica-agent` → Package settings → Change
visibility → Public.

Skipping this means the Docker VM needs a GHCR pull secret. The image contains
no credentials — all auth arrives via environment at runtime.

---

## Step 4 — Prepare the Docker VM

```bash
ssh root@192.168.1.131
```

```bash
mkdir -p /opt/appdata/multica/agent/data /opt/appdata/multica/agent/workspace
echo "=== appdata ==="
ls -ld /opt/appdata/multica/agent/data /opt/appdata/multica/agent/workspace
echo "=== image pull ==="
docker pull ghcr.io/benjsnellings/multica-agent:latest
echo "=== CLI versions in image ==="
docker run --rm --entrypoint /bin/bash ghcr.io/benjsnellings/multica-agent:latest \
  -c 'multica version; claude --version; cursor-agent --version; pi --version'
echo "=== multica server health ==="
curl -fsS https://multica.home.bensnellings.com/health && echo " <- OK"
```

The last check matters: the Multica CLI hits `<server-url>/health` before
authenticating. If it 404s, `MULTICA_SERVER_URL` needs a different base — the
API may not sit at the same host as the web app on your deployment. In that
case point it at the backend container directly over the stack network
(`http://<backend-service>:8080`) and skip the Caddy round-trip.

---

## Step 5 — Add the service and env

Edit `/opt/stacks/multica/compose.yaml` (Dockge web editor is fine). Append to
the `services:` block:

```yaml
  multica-agent:
    image: ghcr.io/benjsnellings/multica-agent:latest
    container_name: multica-agent
    hostname: multica-agent
    restart: unless-stopped
    init: true
    environment:
      HOME: /data
      MULTICA_TOKEN: ${MULTICA_AGENT_TOKEN}
      MULTICA_SERVER_URL: ${MULTICA_SERVER_URL}
      MULTICA_APP_URL: ${MULTICA_APP_URL}
      MULTICA_DEVICE_NAME: "Docker VM (agent)"
      MULTICA_RUNTIME_NAME: ""
      MULTICA_WORKSPACE_ID: ""
      MULTICA_MAX_CONCURRENT_TASKS: 2
      CLAUDE_CODE_OAUTH_TOKEN: ${CLAUDE_CODE_OAUTH_TOKEN:-}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      CURSOR_API_KEY: ${CURSOR_API_KEY:-}
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY:-}
      OPENROUTER_MODEL: anthropic/claude-sonnet-4
      TOOL_UPDATE_INTERVAL_SECONDS: 21600
      TZ: America/Los_Angeles
    volumes:
      - /opt/appdata/multica/agent/data:/data
      - /opt/appdata/multica/agent/workspace:/workspace
    mem_limit: 2g
```

`MULTICA_RUNTIME_NAME` stays empty on purpose — that is what makes Multica
register `claude`, `cursor-agent`, and `pi` as three separate runtimes instead
of collapsing them into one.

Then add to `/opt/stacks/multica/.env`:

```
MULTICA_AGENT_TOKEN=<multica pat>
MULTICA_SERVER_URL=https://multica.home.bensnellings.com
MULTICA_APP_URL=https://multica.home.bensnellings.com
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
ANTHROPIC_API_KEY=
CURSOR_API_KEY=<cursor user api key>
OPENROUTER_API_KEY=<openrouter key>
```

Lock it down — Dockge renders `.env` in its web editor, so anyone who can
reach the Dockge UI can read every key in it:

```bash
chmod 600 /opt/stacks/multica/.env
echo "=== perms ==="
ls -l /opt/stacks/multica/.env
```

---

## Step 6 — Start and verify

```bash
cd /opt/stacks/multica
docker compose up -d multica-agent
echo "=== status ==="
docker compose ps multica-agent
echo "=== auth lines ==="
sleep 10
docker logs multica-agent 2>&1 | grep -E \
  'runtime tool present|CLAUDE_CODE_OAUTH_TOKEN|CURSOR_API_KEY|OpenRouter|Authenticating|Starting Multica'
echo "=== claude non-interactive proof ==="
docker exec multica-agent claude -p "reply with OK and nothing else"
```

**Expected:** three `runtime tool present:` lines with versions, one line per
configured provider, `Authenticating with Multica personal access token from
env`, then `Starting Multica daemon`. The final `claude -p` returning without
a prompt is the real proof that headless auth works.

**Exit code 78** means a configuration or auth failure, not a crash — read the
error line above it rather than letting it restart-loop.

---

## Step 7 — Confirm in Multica

Open <https://multica.home.bensnellings.com> → **Settings → Runtimes**. You
should see **Docker VM (agent)** online with claude, cursor-agent, and pi
listed. Point a task's `local_directory` at `/workspace`.

---

## Maintenance

| Item | Cadence | Action |
|---|---|---|
| Claude OAuth token | ~1 year | `claude setup-token` on the Mac, update `.env`, `docker compose up -d multica-agent` |
| Claude / Cursor / Pi CLIs | automatic | In-container updater runs 30s after start, then every 6h |
| Debian base layer | weekly | GH Actions cron rebuild; `docker compose pull && docker compose up -d multica-agent` to adopt |
| Pinned Multica / Claude / Node baseline | manual | Bump the `ARG`s in the Dockerfile, commit, push |

Roll back to a known-good build any time by pinning the short-SHA tag instead
of `latest` in the compose file.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Exit 78, "No Multica credentials" | `MULTICA_AGENT_TOKEN` empty or `.env` not being read |
| Exit 78, "multica login failed" | Wrong token, or `MULTICA_SERVER_URL` not answering `/health` |
| Claude auth fails despite OAuth token | `ANTHROPIC_API_KEY` also set somewhere and winning |
| `cursor-agent` present but never authenticates | `CURSOR_API_KEY` missing — it's a User API key, not an Admin key |
| Container OOM-killed | Pi's npm update is the heavy step; raise `mem_limit` above 2g |
| Nothing appears in Multica Runtimes | Daemon started but can't reach the server — check `/health` from inside the container |

---

## Outstanding items

- `/opt/stacks/multica/.env` and `/opt/appdata/multica/agent/data` both hold
  credentials on `local-lvm`, which is still not covered by any Proxmox backup
  job. `/data` is the durable home for all four sets of credentials once the
  daemon has authenticated once.
- If `/opt/stacks` gets folded into the Caddy backup/git work, make sure
  `.env` is excluded there too.
