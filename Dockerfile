FROM debian:trixie-slim

# bash with pipefail, so a failure anywhere in a pipe (e.g. gpg | grep) fails the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Match the DSM user/group that own appdata/claude-host on the NAS (check with: id <user>).
# DSM user "docker" is uid 1027, gid 100 (users).
ARG UID=1027
ARG GID=100
# apt channel: "stable" (~1 week behind, skips releases with major regressions) or "latest".
ARG CLAUDE_CHANNEL=stable
# Anthropic Claude Code release signing key. Build fails if the downloaded key doesn't match.
ARG CLAUDE_KEY_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE

# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git openssh-client tmux ripgrep jq less procps; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o /etc/apt/keyrings/claude-code.asc; \
    gpg --batch --show-keys --with-colons /etc/apt/keyrings/claude-code.asc \
      | grep -q "^fpr:.*:${CLAUDE_KEY_FPR}:"; \
    echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/${CLAUDE_CHANNEL} ${CLAUDE_CHANNEL} main" \
      > /etc/apt/sources.list.d/claude-code.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends claude-code; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    getent group "${GID}" >/dev/null || groupadd -g "${GID}" claude; \
    useradd -l -m -u "${UID}" -g "${GID}" -s /bin/bash claude

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# Numeric so file ownership on the NAS volumes is unambiguous.
USER ${UID}:${GID}
ENV HOME=/home/claude
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
