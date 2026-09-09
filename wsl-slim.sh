#!/usr/bin/env bash
# Reclaim disk inside a WSL2 distro: package caches, stale IDE server builds,
# docker leftovers. Portable across machines -- nothing here is host-specific.
#
#   wsl-slim.sh                       clean, keeping what the keep-list protects
#   wsl-slim.sh --compact             then shrink the .vhdx from the Windows side
#   wsl-slim.sh --drop-orphan-volumes also delete unused docker volumes (DESTROYS DB DATA)
#
# Protect project containers/images from the docker sweep with either:
#   export WSL_SLIM_KEEP='^(nginx|php|mysql)-myproject$'
#   or one extended-regex per line in ~/.config/wsl-slim.keep
# Anything currently running is always kept regardless.
set -uo pipefail

DROP_VOLUMES=false
COMPACT=false
for arg in "$@"; do
    case $arg in
        --drop-orphan-volumes) DROP_VOLUMES=true ;;
        --compact)             COMPACT=true ;;
        -h|--help)             sed -n '2,11p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) printf 'wsl-slim: unknown option %s (try --help)\n' "$arg" >&2; exit 2 ;;
    esac
done

KEEP_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/wsl-slim.keep"
keep_pattern() {
    local patterns=()
    [[ -n "${WSL_SLIM_KEEP:-}" ]] && patterns+=("$WSL_SLIM_KEEP")
    [[ -f $KEEP_FILE ]] && while read -r line; do
        [[ -n $line && $line != \#* ]] && patterns+=("$line")
    done < "$KEEP_FILE"
    # A pattern that matches nothing, so an empty keep-list protects nothing.
    [[ ${#patterns[@]} -eq 0 ]] && { printf '$^'; return; }
    local IFS='|'; printf '%s' "${patterns[*]}"
}

section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
used_gb() { df --output=used -BG / | tail -1 | tr -dc '0-9'; }

KEEP=$(keep_pattern)
before=$(used_gb)

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    running=$(docker ps --format '{{.Names}}')
    running_images=$(docker ps --format '{{.Image}}')

    section "Docker: containers"
    docker ps -a --format '{{.Names}}' \
        | grep -Ev "$KEEP" | grep -Fxv "${running:-$'\x01'}" \
        | xargs -r docker rm -f

    section "Docker: images"
    docker images --format '{{.Repository}}:{{.Tag}}' \
        | grep -Ev "$KEEP" | grep -Fxv "${running_images:-$'\x01'}" \
        | xargs -r docker rmi -f 2>/dev/null
    docker image prune -f

    section "Docker: build cache"
    docker builder prune -af

    if $DROP_VOLUMES; then
        section "Docker: unused volumes (DESTRUCTIVE)"
        docker volume prune -af
    fi
else
    section "Docker: not running, skipped"
fi

section "npm cache"
command -v npm >/dev/null && npm cache clean --force 2>/dev/null
rm -rf ~/.npm/_cacache ~/.npm/_npx ~/.npm/_logs

section "pnpm store"
command -v pnpm >/dev/null && pnpm store prune 2>/dev/null
rm -rf ~/.cache/pnpm

section "other caches"
rm -rf ~/.cache/ms-playwright ~/.cache/ms-playwright-go ~/.cache/pip \
       ~/.cache/mise ~/.cache/copilot ~/.cache/composer ~/.nvm/.cache \
       ~/.cache/yarn ~/.cache/go-build
command -v composer >/dev/null && composer clear-cache 2>/dev/null

section "stale IDE server builds (keeps newest of each)"
for d in ~/.vscode-server/bin ~/.cursor-server/bin \
         ~/.antigravity-server/bin ~/.antigravity-ide-server/bin \
         ~/.windsurf-server/bin; do
    [[ -d $d ]] || continue
    ls -1t "$d" | tail -n +2 | while read -r old; do rm -rf "${d:?}/$old"; done
done

section "journal + apt"
sudo journalctl --vacuum-size=50M 2>/dev/null
sudo apt-get clean 2>/dev/null

after=$(used_gb)
printf '\n\033[1mFreed inside WSL: %sG  (%sG -> %sG used)\033[0m\n' \
    "$((before - after))" "$before" "$after"

section "nvm node versions -- prune manually"
ls -1 ~/.nvm/versions/node 2>/dev/null | sed 's/^/  /'
echo "  remove unused with: nvm uninstall <version>"

if ! $COMPACT; then
    cat <<'MSG'

The .vhdx on Windows has NOT shrunk yet -- WSL disks only grow.
Finish it with:  wsl-slim.sh --compact
or by hand from an ELEVATED PowerShell on the host:
  powershell -ExecutionPolicy Bypass -File compact-wsl.ps1
MSG
    exit 0
fi

section "compacting the .vhdx from Windows"

ps1="$(dirname "$(readlink -f "$0")")/compact-wsl.ps1"
if [[ ! -f $ps1 ]]; then
    echo "compact-wsl.ps1 not found next to this script -- skipping compaction." >&2
    exit 1
fi
if ! command -v powershell.exe >/dev/null; then
    echo "powershell.exe unreachable (WSL interop disabled?) -- run compact-wsl.ps1 on the host." >&2
    exit 1
fi

cat <<'MSG'
Handing off to Windows. Accept the UAC prompt -- diskpart needs Administrator.
This shuts WSL down, so THIS SHELL WILL DIE in a moment. That is expected;
the elevated window keeps running and reports what it reclaimed.
MSG

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$ps1")"
