# GitHub Token Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent CLIs (`claude`, `cursor-agent`, `pi`) authenticated GitHub access — clone/pull/push over HTTPS plus issues/PR read-write via the API — driven by a single `GITHUB_TOKEN` env var, following the exact env-var → `configure_provider_auth()` → persisted-in-`/data` pattern already used for Claude/Cursor/OpenRouter.

**Architecture:** Install the `gh` CLI in the image (checksum-verified, same pattern as Node/Multica/Claude). At container start, if `GITHUB_TOKEN` is set, export it as `GH_TOKEN` and run `gh auth setup-git` once — this registers `gh` as git's credential helper for `github.com`, so both `git` and `gh` authenticate from the same token without ever writing it to a plaintext credentials file. Config lands in `/data/.gitconfig` (`HOME=/data` by then), so it persists across restarts like every other provider's auth.

**Tech Stack:** Bash (Dockerfile `RUN`, `entrypoint.sh`), GitHub CLI (`gh`), Docker, GitHub Actions.

Full design rationale: `docs/superpowers/specs/2026-08-27-github-token-access-design.md`.

---

### Task 1: Install `gh` CLI in the Dockerfile

**Files:**
- Modify: `Dockerfile:92-94`

- [ ] **Step 1: Insert the `gh` install block between the Claude and Cursor install steps**

Current text at `Dockerfile:92-94`:

```dockerfile
    && install -m 0755 /tmp/claude /usr/local/bin/claude \
    && rm -f /tmp/claude \
    \
    && curl -fsS https://cursor.com/install | bash \
```

Replace with:

```dockerfile
    && install -m 0755 /tmp/claude /usr/local/bin/claude \
    && rm -f /tmp/claude \
    \
    && GH_TAG="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
         https://github.com/cli/cli/releases/latest | sed 's#.*/tag/##')" \
    && [[ -n "${GH_TAG}" && "${GH_TAG}" == v* ]] \
    && GH_VERSION="${GH_TAG#v}" \
    && echo "Resolved gh ${GH_VERSION}" \
    && GH_TGZ="gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
    && curl -fsSL \
         "https://github.com/cli/cli/releases/download/${GH_TAG}/gh_${GH_VERSION}_checksums.txt" \
         -o /tmp/gh_checksums.txt \
    && curl -fsSL \
         "https://github.com/cli/cli/releases/download/${GH_TAG}/${GH_TGZ}" \
         -o "/tmp/${GH_TGZ}" \
    && grep " ${GH_TGZ}\$" /tmp/gh_checksums.txt | (cd /tmp && sha256sum -c -) \
    && tar -xzf "/tmp/${GH_TGZ}" -C /tmp \
    && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${ARCH}/bin/gh" /usr/local/bin/gh \
    && rm -rf "/tmp/gh_${GH_VERSION}_linux_${ARCH}" "/tmp/${GH_TGZ}" /tmp/gh_checksums.txt \
    \
    && curl -fsS https://cursor.com/install | bash \
```

Note: `gh`'s Linux release assets use the same `amd64`/`arm64` arch names as `dpkg --print-architecture`, so the existing `${ARCH}` variable (set earlier in the `RUN` block) can be reused directly — no separate arch-mapping needed, unlike `MULTICA_ARCH`/`CLAUDE_PLATFORM`.

- [ ] **Step 2: Add `gh` to the resolved-versions report**

Current text at `Dockerfile:104-107` (inside the version-report block):

```dockerfile
         echo "claude=$(claude --version 2>/dev/null | head -n1)"; \
         echo "cursor_agent=$(cursor-agent --version 2>/dev/null | head -n1)"; \
         echo "pi=$(pi --version 2>/dev/null | head -n1)"; \
       } > /etc/multica-agent-versions \
```

Replace with:

```dockerfile
         echo "claude=$(claude --version 2>/dev/null | head -n1)"; \
         echo "cursor_agent=$(cursor-agent --version 2>/dev/null | head -n1)"; \
         echo "pi=$(pi --version 2>/dev/null | head -n1)"; \
         echo "gh=$(gh --version 2>/dev/null | head -n1)"; \
       } > /etc/multica-agent-versions \
```

- [ ] **Step 3: Build the image and verify `gh` installs correctly**

Run: `docker build -t multica-agent:gh-test .`
Expected: build succeeds; the printed `/etc/multica-agent-versions` includes a `gh=gh version X.Y.Z ...` line.

Run: `docker run --rm --entrypoint gh multica-agent:gh-test --version`
Expected: prints the `gh` version with no error.

- [ ] **Step 4: Commit**

Delegate to the `smangings:commit` agent (per repo convention — do not run `git commit` directly). Describe the change as: install the `gh` CLI in the image, checksum-verified, matching the Node/Multica/Claude install pattern.

---

### Task 2: Wire `GITHUB_TOKEN` into `entrypoint.sh`

**Files:**
- Modify: `entrypoint.sh:74-77`

- [ ] **Step 1: Add the GitHub auth branch to `configure_provider_auth()`**

Current text at `entrypoint.sh:74-77`:

```bash
  else
    log info "No OPENROUTER_API_KEY — Pi OpenRouter auth not configured"
  fi
}
```

Replace with:

```bash
  else
    log info "No OPENROUTER_API_KEY — Pi OpenRouter auth not configured"
  fi

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    export GH_TOKEN="${GITHUB_TOKEN}"
    if gh auth setup-git >/dev/null 2>&1; then
      log info "GITHUB_TOKEN set; gh configured as git credential helper"
    else
      log warning "GITHUB_TOKEN set but 'gh auth setup-git' failed"
    fi
  else
    log info "No GITHUB_TOKEN — git/gh will not authenticate to GitHub"
  fi
}
```

`GH_TOKEN` is the env var `gh` and its git credential helper read on every
call — nothing is persisted in plaintext. `gh auth setup-git` itself writes
ordinary git config (credential helper wiring) to `/data/.gitconfig`, which
does persist, so this only needs to run once per fresh `/data` volume; on
subsequent restarts it's a harmless no-op.

- [ ] **Step 2: Verify the authenticated path**

Run:

```bash
docker run --rm -e GITHUB_TOKEN=ghp_fake_token_for_testing \
  --entrypoint /bin/bash multica-agent:gh-test -c '
    export HOME=/tmp/fakehome MULTICA_TOKEN=fake
    mkdir -p "$HOME"
    source /usr/local/bin/entrypoint.sh &
    sleep 2
    git config --global --get-all credential.helper
    kill %1 2>/dev/null || true
  '
```

Expected: log line `GITHUB_TOKEN set; gh configured as git credential helper`, and `git config --global --get-all credential.helper` shows `!gh auth git-credential` (or similar `gh`-backed helper).

Note: this only exercises `configure_provider_auth()` — it will still hit
`die_config` later for the fake `MULTICA_TOKEN` since there's no real
Multica server. That's expected; the check here is only the log line and
the git config side effect, which happen before the Multica login step.

- [ ] **Step 3: Verify the unauthenticated path**

Run:

```bash
docker run --rm --entrypoint /bin/bash multica-agent:gh-test -c '
  export HOME=/tmp/fakehome MULTICA_TOKEN=fake
  mkdir -p "$HOME"
  source /usr/local/bin/entrypoint.sh 2>&1 | grep GITHUB
'
```

Expected: `No GITHUB_TOKEN — git/gh will not authenticate to GitHub` and no error/crash from that block.

- [ ] **Step 4: Commit**

Delegate to the `smangings:commit` agent. Describe the change as: read `GITHUB_TOKEN` in the entrypoint and configure `gh` as git's credential helper, following the same provider-auth pattern as Claude/Cursor/OpenRouter.

---

### Task 3: Add `gh` to the CI smoke test

**Files:**
- Modify: `.github/workflows/build.yml:52-59`

- [ ] **Step 1: Add `gh --version` to the smoke-test step**

Current text at `.github/workflows/build.yml:52-59`:

```yaml
      - name: Smoke test bundled CLIs
        run: |
          docker run --rm --entrypoint /bin/bash multica-agent:candidate -c '
            set -e
            echo "=== multica ==="       && multica version
            echo "=== claude ==="        && claude --version
            echo "=== cursor-agent ===" && cursor-agent --version
            echo "=== pi ==="            && pi --version
            echo "=== node ==="          && node --version
          '
```

Replace with:

```yaml
      - name: Smoke test bundled CLIs
        run: |
          docker run --rm --entrypoint /bin/bash multica-agent:candidate -c '
            set -e
            echo "=== multica ==="       && multica version
            echo "=== claude ==="        && claude --version
            echo "=== cursor-agent ===" && cursor-agent --version
            echo "=== pi ==="            && pi --version
            echo "=== gh ==="            && gh --version
            echo "=== node ==="          && node --version
          '
```

- [ ] **Step 2: Commit**

Delegate to the `smangings:commit` agent. Describe the change as: add `gh --version` to the CI smoke test now that the image bundles the GitHub CLI.

---

### Task 4: Document `GITHUB_TOKEN` in `README.md`

**Files:**
- Modify: `README.md` (config table + new section)

- [ ] **Step 1: Add a `GITHUB_TOKEN` row to the configuration table**

Current text (in the `## Configuration` table):

```markdown
| `OPENROUTER_MODEL` | `anthropic/claude-sonnet-4` | Pi default model. |
| `TOOL_UPDATES` | `true` | Set `false` to disable the background CLI updater. |
```

Replace with:

```markdown
| `OPENROUTER_MODEL` | `anthropic/claude-sonnet-4` | Pi default model. |
| `GITHUB_TOKEN` | — | Fine-grained PAT. Configures `gh` (and git, via `gh auth setup-git`) for clone/pull/push and issues/PR access. See "GitHub access" below. |
| `TOOL_UPDATES` | `true` | Set `false` to disable the background CLI updater. |
```

- [ ] **Step 2: Add a "GitHub access" section**

Add this new section after `## Configuration` (before `## Volumes`):

```markdown
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
```

- [ ] **Step 3: Commit**

Delegate to the `smangings:commit` agent. Describe the change as: document the `GITHUB_TOKEN` env var and the required PAT permissions/branch-protection caveat.

---

### Task 5: Update `SETUP.md`

**Files:**
- Modify: `SETUP.md` (Step 1 credential list, Step 4 CLI-versions check, Step 5 compose block, Step 5 `.env`)

- [ ] **Step 1: Add a credential-gathering step for the GitHub PAT**

Current text at `SETUP.md` Step 1 (after the "1d. Multica" subsection, before "Park all four somewhere safe for Step 5."):

```markdown
### 1d. Multica

A personal access token from **Settings → API Tokens** in your Multica
instance.

Park all four somewhere safe for Step 5.
```

Replace with:

```markdown
### 1d. Multica

A personal access token from **Settings → API Tokens** in your Multica
instance.

### 1e. GitHub (optional)

A **fine-grained personal access token** (Settings → Developer settings →
Personal access tokens → Fine-grained tokens) with:

- Contents: Read and write
- Issues: Read and write
- Pull requests: Read and write

Metadata: Read is included automatically. Skip this if the agents don't
need GitHub access.

Park all five somewhere safe for Step 5.
```

- [ ] **Step 2: Add `gh` to the Step 4 CLI-versions check**

Current text at `SETUP.md` Step 4:

```bash
echo "=== CLI versions in image ==="
docker run --rm --entrypoint /bin/bash ghcr.io/benjsnellings/multica-agent:latest \
  -c 'multica version; claude --version; cursor-agent --version; pi --version'
```

Replace with:

```bash
echo "=== CLI versions in image ==="
docker run --rm --entrypoint /bin/bash ghcr.io/benjsnellings/multica-agent:latest \
  -c 'multica version; claude --version; cursor-agent --version; pi --version; gh --version'
```

- [ ] **Step 3: Add `GITHUB_TOKEN` to the Step 5 compose service block**

Current text at `SETUP.md` Step 5 compose block:

```yaml
      CURSOR_API_KEY: ${CURSOR_API_KEY:-}
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY:-}
      OPENROUTER_MODEL: anthropic/claude-sonnet-4
```

Replace with:

```yaml
      CURSOR_API_KEY: ${CURSOR_API_KEY:-}
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY:-}
      OPENROUTER_MODEL: anthropic/claude-sonnet-4
      GITHUB_TOKEN: ${GITHUB_TOKEN:-}
```

- [ ] **Step 4: Add `GITHUB_TOKEN` to the Step 5 `.env` example**

Current text at `SETUP.md` Step 5 `.env` block:

```
CURSOR_API_KEY=<cursor user api key>
OPENROUTER_API_KEY=<openrouter key>
```

Replace with:

```
CURSOR_API_KEY=<cursor user api key>
OPENROUTER_API_KEY=<openrouter key>
GITHUB_TOKEN=<github fine-grained pat, optional>
```

- [ ] **Step 5: Commit**

Delegate to the `smangings:commit` agent. Describe the change as: document the GitHub PAT setup step and wire `GITHUB_TOKEN` through the deployment runbook's compose/`.env` examples.

---

### Task 6: Update example compose files

**Files:**
- Modify: `examples/compose.yaml`
- Modify: `examples/.env.example`

- [ ] **Step 1: Add `GITHUB_TOKEN` to `examples/compose.yaml`**

Current text at `examples/compose.yaml`:

```yaml
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY:-}
      OPENROUTER_MODEL: anthropic/claude-sonnet-4
      TOOL_UPDATE_INTERVAL_SECONDS: 21600
```

Replace with:

```yaml
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY:-}
      OPENROUTER_MODEL: anthropic/claude-sonnet-4
      GITHUB_TOKEN: ${GITHUB_TOKEN:-}
      TOOL_UPDATE_INTERVAL_SECONDS: 21600
```

- [ ] **Step 2: Add `GITHUB_TOKEN` to `examples/.env.example`**

Current text at `examples/.env.example`:

```
# Pi via OpenRouter
OPENROUTER_API_KEY=
OPENROUTER_MODEL=anthropic/claude-sonnet-4
```

Replace with:

```
# Pi via OpenRouter
OPENROUTER_API_KEY=
OPENROUTER_MODEL=anthropic/claude-sonnet-4

# --- GitHub access (optional) -------------------------------------------------
# Fine-grained PAT: Contents, Issues, Pull requests = Read and write.
# Does not stop the agent from calling the merge endpoint — enforce that with
# branch protection (require an approving review) on repos you care about.
GITHUB_TOKEN=
```

- [ ] **Step 3: Commit**

Delegate to the `smangings:commit` agent. Describe the change as: add `GITHUB_TOKEN` to the example compose service and `.env` template.

---

### Task 7: Full local verification

**Files:** none (verification only)

- [ ] **Step 1: Full image build**

Run: `docker build -t multica-agent:gh-final .`
Expected: succeeds; version report includes `gh=gh version ...`.

- [ ] **Step 2: Re-run the CI smoke test locally**

Run:

```bash
docker run --rm --entrypoint /bin/bash multica-agent:gh-final -c '
  set -e
  multica version
  claude --version
  cursor-agent --version
  pi --version
  gh --version
  node --version
'
```

Expected: all six commands print a version with no error.

- [ ] **Step 3: Confirm `docs/superpowers/specs/2026-08-27-github-token-access-design.md` still matches what was built**

Read through the spec once more against the diff (`git diff main`); note any drift (there shouldn't be any — this plan implements it as written).

No commit needed for this task — it's verification only.
