# multica-agent

A standalone [Multica](https://github.com/multica-ai/multica) daemon container
bundling **Claude Code**, **Cursor Agent**, and **Pi**, published to GHCR.

Upstream ships server images only — the daemon is designed to run on the
execution machine, and Multica deliberately does not bundle the agent CLIs.
This image packages the daemon plus the three CLIs so a runtime can be a
compose service instead of a machine you have to hand-maintain.

```
ghcr.io/benjsnellings/multica-agent:latest
```

## Quick start

```bash
mkdir -p /opt/appdata/multica/agent/{data,workspace}
cp examples/compose.yaml examples/.env.example ./
mv .env.example .env    # fill in MULTICA_AGENT_TOKEN + provider keys
docker compose up -d
docker compose logs -f multica-agent
```

The runtime appears under **Settings → Runtimes** in Multica once the daemon
authenticates.

## Configuration

All configuration is environment variables — there is no config file.

| Variable | Default | Purpose |
|---|---|---|
| `MULTICA_TOKEN` | — | Personal access token. Required on first start; afterwards credentials persist in `/data`. |
| `MULTICA_SERVER_URL` | `https://api.multica.ai` | API base. Point at your self-hosted instance. |
| `MULTICA_APP_URL` | `https://multica.ai` | Web app URL, written to the CLI config. |
| `MULTICA_DEVICE_NAME` | container hostname | Runtime name shown in Multica. |
| `MULTICA_RUNTIME_NAME` | *(empty)* | Leave empty so claude / cursor-agent / pi register as separate runtimes. |
| `MULTICA_WORKSPACE_ID` | *(empty)* | Optional workspace to switch to on start. |
| `MULTICA_MAX_CONCURRENT_TASKS` | `2` | Parallel task limit. |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | Claude Code via Pro/Max subscription. Takes precedence over the API key. |
| `ANTHROPIC_API_KEY` | — | Claude Code via Console/API billing. |
| `CURSOR_API_KEY` | — | Cursor Agent plan auth. |
| `OPENROUTER_API_KEY` | — | Pi auth; written to `/data/.pi/agent/auth.json`. |
| `OPENROUTER_MODEL` | `anthropic/claude-sonnet-4` | Pi default model. |
| `GITHUB_TOKEN` | — | Fine-grained PAT. Configures `gh` (and git, via `gh auth setup-git`) for clone/pull/push and issues/PR access. See "GitHub access" below. |
| `TOOL_UPDATES` | `true` | Set `false` to disable the background CLI updater. |
| `TOOL_UPDATE_INTERVAL_SECONDS` | `21600` | Updater interval (6h). |
| `TOOL_UPDATE_BOOT_DELAY_SECONDS` | `30` | Delay before the first update run. |

## GitHub access

Set `GITHUB_TOKEN` to a **fine-grained personal access token** with:

| Permission | Level |
|---|---|
| Contents | Read and write |
| Issues | Read and write |
| Pull requests | Read and write |
| Metadata | Read (mandatory) |

The entrypoint exports it as `GH_TOKEN` and runs `gh auth setup-git`, which
wires `gh` up as git's credential helper for `github.com` — both `git`
(clone/pull/push) and `gh` (issues, PRs) authenticate from the same token.
Nothing is written to disk in plaintext; the token is resolved from the env
var on every call.

**This does not prevent the token from merging PRs.** Fine-grained tokens
have no separate "merge" permission — `Pull requests: write` technically
permits it. To actually block merges, enable branch protection on the
target repo requiring at least one approving review; GitHub enforces that
regardless of what the token's API access allows.

## Volumes

| Path | Purpose |
|---|---|
| `/data` | Multica credentials, Claude/Cursor/Pi auth and state, npm cache. **Back this up.** |
| `/workspace` | Agent working directory — point Multica's `local_directory` here. |

## Design notes

- **Debian base is mandatory.** Cursor Agent's bundled Node needs `fcntl64`
  and fails on Alpine/musl.
- **Node is installed from the official tarball**, not apt — bookworm ships
  Node 18 and Pi needs ≥ 22.19 for `/v` regex support.
- **`IS_SANDBOX=1`** so Claude Code permits `bypassPermissions` while running
  as root in a container (anthropics/claude-code#9184).
- **`HOME=/root` at build time, `/data` at runtime.** The Cursor installer
  writes to `$HOME/.local`; seeding it under `/root` keeps it out of the
  bind-mounted `/data`, and the updater reinstalls into `/data/.local` where
  it persists.
- **Exit 78 is a config/auth failure**, not a crash — check the logs rather
  than letting the container restart-loop.
- **Nothing is version-pinned.** Every component resolves to its latest
  release at build time; `/etc/multica-agent-versions` inside the image records
  exactly what landed. Downloads are still checksum-verified. Pin a build by
  deploying a short-SHA image tag rather than `latest`.

## Building locally

```bash
docker build -t multica-agent:local .
```

## Credits

The image build and `update-agent-tools` originate from the Multica Home
Assistant add-ons in
[benjsnellings/home-assistant-addons](https://github.com/benjsnellings/home-assistant-addons),
with the s6-overlay and Supervisor-specific plumbing removed.
