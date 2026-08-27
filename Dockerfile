FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/benjsnellings/multica-agent" \
      org.opencontainers.image.description="Multica daemon with Claude Code, Cursor Agent, and Pi CLIs" \
      org.opencontainers.image.licenses="MIT"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Build-time HOME=/root so the Cursor installer seeds the image outside /data
# (/data is a bind mount at runtime). Entrypoint flips HOME to /data.
ENV HOME=/root \
    DEBIAN_FRONTEND=noninteractive \
    IS_SANDBOX=1

# Changing REFRESH invalidates the layer below so a rebuild actually picks up
# new upstream releases instead of serving a cached layer. The workflow passes
# the current date.
ARG REFRESH=unset

# Every component resolves to its latest release at build time. Downloads are
# still checksum-verified (Node SHASUMS256.txt, Multica checksums.txt, Claude
# manifest.json) — that guards against corrupt or truncated transfers, not
# against a compromised upstream, since checksum and artifact share an origin.
#
# Debian/glibc base is mandatory: Cursor Agent's bundled Node needs fcntl64 and
# fails on Alpine/musl.
RUN \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        less \
        openssh-client \
        procps \
        ripgrep \
        tar \
        tzdata \
        xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    \
    && ARCH="$(dpkg --print-architecture)" \
    && case "${ARCH}" in \
         amd64) MULTICA_ARCH="amd64"; CLAUDE_PLATFORM="linux-x64";   NODE_ARCH="x64"   ;; \
         arm64) MULTICA_ARCH="arm64"; CLAUDE_PLATFORM="linux-arm64"; NODE_ARCH="arm64" ;; \
         *) echo "Unsupported arch: ${ARCH}" >&2; exit 1 ;; \
       esac \
    \
    && NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/index.json \
         | jq -r '[.[] | select(.lts != false)][0].version')" \
    && [[ -n "${NODE_VERSION}" && "${NODE_VERSION}" != "null" ]] \
    && echo "Resolved Node ${NODE_VERSION}" \
    && NODE_TGZ="node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
    && curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/${NODE_TGZ}" -o "/tmp/${NODE_TGZ}" \
    && curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt" -o /tmp/SHASUMS256.txt \
    && (cd /tmp && grep " ${NODE_TGZ}\$" SHASUMS256.txt | sha256sum -c -) \
    && tar -xJf "/tmp/${NODE_TGZ}" -C /usr/local --strip-components=1 \
    && rm -f "/tmp/${NODE_TGZ}" /tmp/SHASUMS256.txt \
    && node --version && npm --version \
    \
    && MULTICA_TAG="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
         https://github.com/multica-ai/multica/releases/latest | sed 's#.*/tag/##')" \
    && [[ -n "${MULTICA_TAG}" && "${MULTICA_TAG}" == v* ]] \
    && MULTICA_VERSION="${MULTICA_TAG#v}" \
    && echo "Resolved Multica ${MULTICA_VERSION}" \
    && MULTICA_TGZ="multica-cli-${MULTICA_VERSION}-linux-${MULTICA_ARCH}.tar.gz" \
    && curl -fsSL \
         "https://github.com/multica-ai/multica/releases/download/${MULTICA_TAG}/checksums.txt" \
         -o /tmp/checksums.txt \
    && curl -fsSL \
         "https://github.com/multica-ai/multica/releases/download/${MULTICA_TAG}/${MULTICA_TGZ}" \
         -o "/tmp/${MULTICA_TGZ}" \
    && grep " ${MULTICA_TGZ}\$" /tmp/checksums.txt | (cd /tmp && sha256sum -c -) \
    && tar -xzf "/tmp/${MULTICA_TGZ}" -C /tmp \
    && install -m 0755 /tmp/multica /usr/local/bin/multica \
    && rm -rf /tmp/multica "/tmp/${MULTICA_TGZ}" /tmp/checksums.txt \
    \
    && CLAUDE_VERSION="$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest)" \
    && [[ -n "${CLAUDE_VERSION}" ]] \
    && CLAUDE_SHA256="$(curl -fsSL \
         "https://downloads.claude.ai/claude-code-releases/${CLAUDE_VERSION}/manifest.json" \
         | jq -r --arg p "${CLAUDE_PLATFORM}" '.platforms[$p].checksum // empty')" \
    && [[ -n "${CLAUDE_SHA256}" ]] \
    && echo "Resolved Claude Code ${CLAUDE_VERSION}" \
    && curl -fsSL \
         "https://downloads.claude.ai/claude-code-releases/${CLAUDE_VERSION}/${CLAUDE_PLATFORM}/claude" \
         -o /tmp/claude \
    && echo "${CLAUDE_SHA256}  /tmp/claude" | sha256sum -c - \
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
    && ln -sfn /root/.local/bin/cursor-agent /usr/local/bin/cursor-agent \
    && ln -sfn /root/.local/bin/agent /usr/local/bin/agent \
    \
    && npm install -g --omit=dev @earendil-works/pi-coding-agent@latest \
    \
    && { \
         echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
         echo "arch=${ARCH}"; \
         echo "node=$(node --version)"; \
         echo "multica=$(multica version 2>/dev/null | head -n1)"; \
         echo "claude=$(claude --version 2>/dev/null | head -n1)"; \
         echo "cursor_agent=$(cursor-agent --version 2>/dev/null | head -n1)"; \
         echo "pi=$(pi --version 2>/dev/null | head -n1)"; \
         echo "gh=$(gh --version 2>/dev/null | head -n1)"; \
       } > /etc/multica-agent-versions \
    && cat /etc/multica-agent-versions

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY update-agent-tools /usr/local/bin/update-agent-tools
RUN chmod a+x /usr/local/bin/entrypoint.sh /usr/local/bin/update-agent-tools \
    && mkdir -p /data /workspace

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
