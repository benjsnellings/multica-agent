# GitHub token access for agent CLIs

## Problem

The agents running inside the container (`claude`, `cursor-agent`, `pi`) have
`git` and `openssh-client` available but no configured GitHub credentials.
They need to clone/pull private repos, push branches, and read/write issues
and pull requests (opening, commenting, reviewing — **not** merging).

## Decision: `gh` CLI + `GH_TOKEN`, not a raw git credential file or SSH key

Plain `git` plus a `.git-credentials` file only covers clone/push over HTTPS —
it has no path to the GitHub API, so issues and PRs would need a second
mechanism anyway. An SSH deploy key has the same gap and is also
single-repo-oriented, which doesn't fit "all repos."

`gh` covers both with one token and one mechanism:

- `gh auth setup-git` registers `gh` as git's credential helper for
  `github.com` / `gist.github.com`, so `git clone` / `git push` over HTTPS
  authenticate automatically.
- `gh` and its git credential helper resolve the token from the `GH_TOKEN`
  env var at call time — nothing is written to disk in plaintext, unlike a
  `.git-credentials` file.
- `gh issue *` / `gh pr *` gives direct issue and PR create/comment/review
  support.

## Token type and permissions

A **fine-grained personal access token**, scoped to **all repositories**:

| Permission | Level | Why |
|---|---|---|
| Contents | Read and write | clone / pull / push |
| Issues | Read and write | file / update issues |
| Pull requests | Read and write | open / comment / review PRs |
| Metadata | Read (mandatory) | required by every fine-grained token |

**Caveat — this does not block merging.** Fine-grained tokens have no
separate "merge" permission; `Pull requests: write` technically permits
calling the merge endpoint too. Token scope alone cannot enforce "no merge."
The actual enforcement point is **branch protection on each target repo**:
require at least one approving review before merge, so GitHub rejects a
merge call from the token even though the token has API access to attempt
it. This is a per-repo GitHub setting, not something this container can
configure — documented as a required companion step, not implemented here.

## Components

1. **`Dockerfile`** — add a `gh` CLI install step in the existing `RUN`
   block, following the established pattern (Node/Multica/Claude): resolve
   the latest release via the GitHub API, download the arch-specific
   tarball, verify against `gh`'s published `checksums.txt`, install to
   `/usr/local/bin`.
2. **`entrypoint.sh`** — in `configure_provider_auth()`, add a branch: if
   `GITHUB_TOKEN` is set, `export GH_TOKEN="${GITHUB_TOKEN}"` and run
   `gh auth setup-git` (idempotent; writes to `/data/.gitconfig` since
   `HOME=/data` by that point, so it persists across restarts like every
   other provider's auth). Log presence/absence the same way the other
   providers do.
3. **`README.md`** — add `GITHUB_TOKEN` to the configuration table; add a
   short "GitHub access" section documenting the permissions above and the
   branch-protection caveat.
4. **`SETUP.md`** — add a credential-gathering step for the fine-grained PAT
   (mirroring the existing Claude/Cursor/Pi/Multica steps), and add
   `GITHUB_TOKEN` to the compose service env block and `.env` template in
   the deployment walkthrough.
5. **`examples/compose.yaml`** — add `GITHUB_TOKEN: ${GITHUB_TOKEN:-}` to
   the `environment:` block, matching the `CURSOR_API_KEY` /
   `OPENROUTER_API_KEY` pass-through pattern.
6. **`update-agent-tools`** — intentionally **not** touched. `gh`, like
   `git`/`jq`/`curl`, is pinned at image build time and refreshed by the
   weekly base-layer rebuild cron; only the three AI CLIs (`claude`,
   `cursor-agent`, `pi`) get the 6-hourly hot-update treatment.

## Out of scope

- Configuring branch protection on any target repo (external to this
  container/repo).
- Auto-updating `gh` in `update-agent-tools`.
- Any SSH-key-based git auth path.

## Status

User already generated the fine-grained PAT (all repos; Contents, Issues,
Pull requests: read/write) and added `GITHUB_TOKEN` to the deployment's
compose env. Remaining work is entirely in this repo (Dockerfile,
entrypoint.sh, docs, example compose).
