# claude-host

Always-on Claude Code on the Synology, driven from the Claude app and claude.ai/code via **Remote Control** server mode. Outbound HTTPS only; no ports, no tunnel.

Source of truth for design and operations: Notion → Projects → **Claude Host** (Design and Runbook pages).

## Where things live

| What | Where |
|---|---|
| Development clones | `~/src/claude-host` on each laptop |
| Source of truth | Gitea `paul/claude-host` (mirrored to GitHub `itsgiff/claude-host`) |
| Deploy copy (pull only, never edit) | `/volume1/docker/build/claude-host` on the NAS |
| Service definition | `claude-host` in `/volume1/docker/storage-compose.yml` |
| Live data (login, ssh key, repos) | `/volume1/docker/appdata/claude-host/{home,work}`: SECRET |

## Repo layout

    Dockerfile               # Debian trixie-slim + Claude Code (signed apt repo, stable)
    entrypoint.sh            # preflight checks + supervisor with backoff
    tests/entrypoint_test.sh # smoke tests with a stub claude (run by pre-commit)
    host.sh                  # NAS helper: init, build, bootstrap, logs, shell, doctor
    settings.template.json   # starter ~/.claude/settings.json
    .env.example             # HOST_UID / HOST_GID / DATA_DIR only, no secrets

## Develop (laptop)

    git clone gitea:paul/claude-host.git ~/src/claude-host
    cd ~/src/claude-host && pre-commit install

Branch, commit with `gcm`, open a PR in Gitea; merges are fast-forward only.

## First deploy (NAS)

    git clone gitea:paul/claude-host.git /volume1/docker/build/claude-host
    cd /volume1/docker/build/claude-host
    cp .env.example .env            # set HOST_UID/HOST_GID from: id <dsm-user>
    ./host.sh init                  # appdata/claude-host/{home,work}, seed settings.json
    ./host.sh build
    ./host.sh bootstrap             # interactive shell in a throwaway container, then:
    #   claude auth login           # claude.ai option, finish sign-in on phone/laptop
    #   claude                      # trust /work; /config → turn on both push options; exit
    #   claude remote-control       # answer y to enable; check the app; Ctrl+C; exit

Then add the `claude-host` service to `storage-compose.yml` and run `compose.sh up`.

## Day to day (NAS)

| Command | Does |
|---|---|
| `./host.sh status` | container state and health |
| `./host.sh logs` | follow logs |
| `./host.sh shell` | bash inside the running container (re-login, fixes) |
| `./host.sh doctor` | `claude doctor` inside the container |
| `./host.sh restart` | restart; sessions resume |
| `git pull --ff-only && ./host.sh rebuild`, then `compose.sh up` | deploy a new version or a new Claude Code release |

## Rules

- Never put `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or `DISABLE_GROWTHBOOK` in the service environment. The entrypoint refuses to start if they're set.
- Mount nothing beyond `appdata/claude-host/home` and `appdata/claude-host/work`. No Docker socket, no `/volume1`.
- The deploy copy on the NAS only changes through `git pull --ff-only`.
