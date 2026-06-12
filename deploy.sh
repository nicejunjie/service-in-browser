#!/usr/bin/env bash
# deploy.sh — one-command full deploy of Vibetop (the whole stack).
#
#   ./deploy.sh                   deploy on THIS machine
#   ./deploy.sh --remote HOST     rsync this repo to HOST:~/vibetop and deploy there
#                                 (HOST is any ssh destination: user@ip or an
#                                  ssh-config Host; a bare shell alias won't work)
#
# Flags:
#   --remote HOST    deploy to a remote host over SSH (rsync first)
#   --no-browser     skip the xpra/Chromium Browser stack (heavy: xpra repo + snap)
#   --no-files       skip FileBrowser (the Files app)
#   --with-tunnel    also run the interactive Cloudflare tunnel installer
#   --dry-run        print what each installer would do, change nothing
#   --help
#
# Order matters: terminal first (owns the nginx site + the extras include),
# then browser/files (drop extras snippets), then landing (static UI), tunnel last.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REMOTE="" ; DO_BROWSER=1 ; DO_FILES=1 ; DO_TUNNEL=0 ; DRY=0
PASS=()   # flags forwarded to the remote invocation of this script
while [ $# -gt 0 ]; do
    case "$1" in
        --remote)      REMOTE="${2:?--remote needs a host}"; shift 2 ;;
        --no-browser)  DO_BROWSER=0; PASS+=("$1"); shift ;;
        --no-files)    DO_FILES=0;   PASS+=("$1"); shift ;;
        --with-tunnel) DO_TUNNEL=1;  PASS+=("$1"); shift ;;
        --dry-run|-n)  DRY=1;        PASS+=("--dry-run"); shift ;;
        --help|-h)     sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# --- Remote mode: ship the repo, run ourselves on the far side, health-check ---
if [ -n "$REMOTE" ]; then
    echo "==> syncing repo to $REMOTE:~/vibetop"
    # Include .git so the target is a real checkout (the in-app Updater runs
    # `git log`/`git pull`); it's tiny. Then repoint origin at HTTPS so the
    # Updater can pull a public repo without an SSH key on the target.
    rsync -az --delete --exclude='*.pyc' "$REPO_DIR/" "$REMOTE":vibetop/
    https_url="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null | sed -E 's#git@([^:]+):#https://\1/#' || true)"
    if [ -n "$https_url" ]; then
        ssh "$REMOTE" "git -C ~/vibetop remote set-url origin '$https_url' 2>/dev/null || true; git config --global --add safe.directory ~/vibetop 2>/dev/null || true"
    fi
    echo "==> deploying on $REMOTE"
    ssh "$REMOTE" "cd ~/vibetop && DEBIAN_FRONTEND=noninteractive ./deploy.sh ${PASS[*]:-}"
    echo "==> remote health check (loopback http codes)"
    ssh "$REMOTE" 'for p in / /t1/ /terminals/ /files/ /browser/ /api/system/status; do printf "  %-24s " "$p"; curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 --retry 6 --retry-delay 2 --retry-all-errors "http://127.0.0.1$p" || echo "ERR"; done'
    ip=$(ssh "$REMOTE" "hostname -I | awk '{print \$1}'" 2>/dev/null)
    echo "==> done. Open http://${ip:-<remote-ip>}/ on your LAN."
    exit 0
fi

# --- Local mode -------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
DRYFLAG=(); (( DRY )) && DRYFLAG=(--dry-run)
step() { echo; echo "### $*"; }

step "1/5  Terminal — nginx site + manager + ttyd"
sudo "$REPO_DIR/terminal/install.sh" "${DRYFLAG[@]}"

if (( DO_BROWSER )); then
    step "2/5  Browser — xpra + Chromium"
    sudo "$REPO_DIR/browser/install.sh" "${DRYFLAG[@]}"
else
    step "2/5  Browser — skipped (--no-browser)"
fi

if (( DO_FILES )); then
    step "3/5  Files — FileBrowser"
    sudo "$REPO_DIR/files/install.sh" "${DRYFLAG[@]}"
else
    step "3/5  Files — skipped (--no-files)"
fi

step "4/5  Landing — desktop UI + static apps"
"$REPO_DIR/landing/install.sh" "${DRYFLAG[@]}"

if (( DO_TUNNEL )); then
    step "5/5  Tunnel — Cloudflare (interactive)"
    sudo "$REPO_DIR/tunnel/install.sh" "${DRYFLAG[@]}"
else
    step "5/5  Tunnel — skipped (run with --with-tunnel; it's interactive)"
fi

if (( ! DRY )); then
    step "health check (loopback http codes)"
    for p in / /t1/ /terminals/ /files/ /browser/ /api/system/status; do
        printf "  %-24s " "$p"
        curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 --retry 6 --retry-delay 2 --retry-all-errors "http://127.0.0.1$p" || echo "ERR"
    done
fi
echo
echo "Vibetop deployed. Open http://<this-host>/ on your LAN."
