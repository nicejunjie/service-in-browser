#!/usr/bin/env bash
# One-command deploy for claude-office: OnlyOffice Document Server in Docker,
# fronted by nginx at /onlyoffice/. Powers the Files app's "Edit" (fast,
# native-in-browser editing) and saves back to the file via the manager's
# /api/office/{config,doc,callback,forcesave} endpoints.
#
#   browser <-> nginx /onlyoffice/ <-> 127.0.0.1:ONLYOFFICE_PORT (docker)
#   docker  <-> host.docker.internal/api/office/* (doc fetch + save callback)
#
# Env knobs:
#   ONLYOFFICE_PORT   loopback port for the container         (default 8087)
#   ONLYOFFICE_IMAGE  image to run               (default onlyoffice/documentserver)
#   INSTALL_DEPS      docker pull the image                   (default 1)
#   INSTALL_NGINX     render & reload the nginx snippet       (default 1)
#   DRY_RUN           print actions only                      (default 0)
set -euo pipefail

APP_USER="${APP_USER:-${SUDO_USER:-$(id -un)}}"
APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
ONLYOFFICE_PORT="${ONLYOFFICE_PORT:-8087}"
ONLYOFFICE_IMAGE="${ONLYOFFICE_IMAGE:-onlyoffice/documentserver:latest}"
CONTAINER="vibetop-onlyoffice"
SECRET_FILE="$APP_HOME/.config/vibetop/onlyoffice.secret"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
INSTALL_NGINX="${INSTALL_NGINX:-1}"
DRY_RUN="${DRY_RUN:-0}"

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --no-nginx) INSTALL_NGINX=0 ;;
        --help|-h) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

run() { if (( DRY_RUN )); then printf '+ %s\n' "$*"; else "$@"; fi; }
write_root() { if (( DRY_RUN )); then echo "+ write -> $1"; sed 's/^/    | /'; else sudo tee "$1" >/dev/null; fi; }
# Write an nginx conf from stdin only if it actually differs, and flag a single
# reload. Skipping no-op writes avoids reloading nginx (which severs live
# terminal/Browser/Office WebSockets) when nothing changed.
NGINX_DIRTY=0
nginx_write() {
    local dest="$1" tmp; tmp="$(mktemp)"; cat >"$tmp"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
    if (( DRY_RUN )); then echo "+ nginx: would update $dest"; else sudo install -m 0644 "$tmp" "$dest"; fi
    rm -f "$tmp"; NGINX_DIRTY=1
}

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required but not installed. Install Docker, then re-run." >&2
    exit 1
fi

echo "== claude-office (OnlyOffice Document Server) =="
echo "   user: $APP_USER   port: $ONLYOFFICE_PORT   image: $ONLYOFFICE_IMAGE"

# 1. JWT secret — shared between the container and the manager. Generated once.
if [ ! -s "$SECRET_FILE" ]; then
    echo "== generating JWT secret =="
    run sudo -u "$APP_USER" install -d -m 0750 "$APP_HOME/.config/vibetop"
    if (( ! DRY_RUN )); then
        openssl rand -hex 32 | sudo -u "$APP_USER" tee "$SECRET_FILE" >/dev/null
        sudo -u "$APP_USER" chmod 0600 "$SECRET_FILE"
    fi
fi
SECRET="$( (( DRY_RUN )) && echo DRYRUN || sudo cat "$SECRET_FILE")"

# 2. Image
if (( INSTALL_DEPS )); then
    echo "== pulling image (large, ~2GB first time) =="
    run docker pull "$ONLYOFFICE_IMAGE"
fi

# 3. (Re)create the container — loopback only; reachable back to the host for
#    the doc fetch + save callback via host.docker.internal.
echo "== (re)creating container $CONTAINER =="
run docker rm -f "$CONTAINER" 2>/dev/null || true
run docker run -d --name "$CONTAINER" --restart unless-stopped \
    -p "127.0.0.1:${ONLYOFFICE_PORT}:80" \
    -e JWT_ENABLED=true -e JWT_SECRET="$SECRET" -e JWT_HEADER=Authorization \
    --add-host=host.docker.internal:host-gateway \
    "$ONLYOFFICE_IMAGE"

# 4. nginx snippet
if (( INSTALL_NGINX )); then
    if ! [ -d /etc/nginx/snippets/claude-extras.d ]; then
        echo "   /etc/nginx/snippets/claude-extras.d missing — run terminal/install.sh first." >&2
        exit 1
    fi
    echo "== installing nginx snippet =="
    sed -e "s|@ONLYOFFICE_PORT@|$ONLYOFFICE_PORT|g" \
        "$APP_DIR/nginx/onlyoffice.conf" \
        | nginx_write /etc/nginx/snippets/claude-extras.d/onlyoffice.conf
    if (( NGINX_DIRTY )); then
        run sudo nginx -t && run sudo systemctl reload nginx
    else
        echo "   nginx unchanged — skipping reload"
    fi
fi

echo
echo "done. The Document Server takes ~1-2 min to become healthy on first start:"
echo "  curl -s http://127.0.0.1:${ONLYOFFICE_PORT}/healthcheck   # -> true"
echo "  open the Office app via Files -> Edit"
