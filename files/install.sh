#!/usr/bin/env bash
# Install FileBrowser as the Vibetop "Files" app: served at /files/ from
# 127.0.0.1:8085, rooted at the user's home, no auth (Cloudflare Access or the
# LAN boundary is the gate). Idempotent and re-runnable. --dry-run previews.
#
# Run AFTER terminal/install.sh (which creates the nginx extras dir + include).
#
# Configurable via env vars (all optional):
#   APP_USER         system user that owns the files          (default: invoking user)
#   APP_DIR          where this script lives                  (default: script dir)
#   FB_PORT          loopback port FileBrowser binds          (default 8085)
#   FB_BIN           filebrowser binary path                  (default /usr/local/bin/filebrowser)
#   INSTALL_DEPS     download the filebrowser binary if absent (default 1)
#   INSTALL_SYSTEMD  render & enable the systemd unit          (default 1)
#   INSTALL_NGINX    write the /files/ nginx snippet           (default 1)
#   DRY_RUN          print actions without executing           (default 0)
set -euo pipefail

APP_USER="${APP_USER:-${SUDO_USER:-$(id -un)}}"
APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
FB_PORT="${FB_PORT:-8085}"
FB_BIN="${FB_BIN:-/usr/local/bin/filebrowser}"
FB_VERSION="${FB_VERSION:-v2.63.3}"
FB_DB="$APP_HOME/.config/filebrowser/filebrowser.db"
NGINX_EXTRAS="/etc/nginx/snippets/claude-extras.d"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
INSTALL_SYSTEMD="${INSTALL_SYSTEMD:-1}"
INSTALL_NGINX="${INSTALL_NGINX:-1}"
DRY_RUN="${DRY_RUN:-0}"

for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        --help|-h) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

run() { if (( DRY_RUN )); then printf '+ %s\n' "$*"; else "$@"; fi; }
write_root() {
    local dest="$1"
    if (( DRY_RUN )); then echo "+ write -> $dest"; sed 's/^/    | /'
    else sudo tee "$dest" >/dev/null; fi
}
# Write an nginx conf from stdin only if it differs; flag a single reload so a
# no-op deploy doesn't reload nginx (which severs live terminal/Browser sockets).
NGINX_DIRTY=0
nginx_write() {
    local dest="$1" tmp; tmp="$(mktemp)"; cat >"$tmp"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
    if (( DRY_RUN )); then echo "+ nginx: would update $dest"; else sudo install -m 0644 "$tmp" "$dest"; fi
    rm -f "$tmp"; NGINX_DIRTY=1
}
fb() { run sudo -u "$APP_USER" "$FB_BIN" --database "$FB_DB" "$@"; }

cat <<EOF
filebrowser install
  user        : $APP_USER   (home $APP_HOME)
  port        : 127.0.0.1:$FB_PORT  ->  /files/   (root: $APP_HOME, no auth)
  binary / db : $FB_BIN  |  $FB_DB
  deps        : $INSTALL_DEPS   systemd: $INSTALL_SYSTEMD   nginx: $INSTALL_NGINX
  dry run     : $DRY_RUN
EOF
echo

# 1. Binary ------------------------------------------------------------------
if (( INSTALL_DEPS )) && ! [ -x "$FB_BIN" ]; then
    echo "== installing filebrowser $FB_VERSION binary =="
    if ! command -v curl >/dev/null 2>&1; then
        run sudo apt-get update -qq && run sudo apt-get install -y curl
    fi
    case "$(uname -m)" in
        x86_64)        fb_arch=amd64 ;;
        aarch64|arm64) fb_arch=arm64 ;;
        armv7l)        fb_arch=armv7 ;;
        i386|i686)     fb_arch=386 ;;
        riscv64)       fb_arch=riscv64 ;;
        *) echo "unsupported arch $(uname -m) for filebrowser" >&2; exit 1 ;;
    esac
    # The release tarball holds the binary plus docs at its root; extract just it.
    url="https://github.com/filebrowser/filebrowser/releases/download/${FB_VERSION}/linux-${fb_arch}-filebrowser.tar.gz"
    run bash -c "curl -fsSL '$url' | sudo tar -xz -C /usr/local/bin filebrowser && sudo chmod 0755 /usr/local/bin/filebrowser"
fi
if ! [ -x "$FB_BIN" ] && (( ! DRY_RUN )); then
    echo "filebrowser binary not found at $FB_BIN (set FB_BIN or INSTALL_DEPS=1)" >&2
    exit 1
fi

# 2. Config (run as APP_USER; stop the service first so the bolt db isn't locked)
echo "== configuring filebrowser db =="
run sudo systemctl stop claude-web-filebrowser.service 2>/dev/null || true
run sudo -u "$APP_USER" mkdir -p "$APP_HOME/.config/filebrowser"
if ! [ -f "$FB_DB" ] && (( ! DRY_RUN )); then
    fb config init
    # noauth needs one user to act as; create an admin (only used internally).
    fb users add admin "$(openssl rand -hex 12 2>/dev/null || echo changeme123)" --perm.admin || true
fi
# Settings are idempotent — safe to set on every run.
fb config set --address 127.0.0.1 --port "$FB_PORT" --baseurl /files \
              --root "$APP_HOME" --auth.method=noauth

# 3. systemd unit ------------------------------------------------------------
if (( INSTALL_SYSTEMD )); then
    echo "== installing systemd unit =="
    sed -e "s|@APP_USER@|$APP_USER|g" \
        -e "s|@APP_HOME@|$APP_HOME|g" \
        -e "s|@FB_BIN@|$FB_BIN|g" \
        -e "s|@FB_DB@|$FB_DB|g" \
        "$APP_DIR/systemd/claude-web-filebrowser.service" \
        | write_root /etc/systemd/system/claude-web-filebrowser.service
    run sudo systemctl daemon-reload
    run sudo systemctl enable --now claude-web-filebrowser.service
else
    run sudo systemctl restart claude-web-filebrowser.service 2>/dev/null || true
fi

# 4. nginx snippet -----------------------------------------------------------
if (( INSTALL_NGINX )); then
    echo "== installing /files/ nginx snippet =="
    if ! [ -d "$NGINX_EXTRAS" ]; then
        echo "   $NGINX_EXTRAS does not exist — run terminal/install.sh first" >&2
        exit 1
    fi
    sed -e "s|@APP_HOME@|$APP_HOME|g" \
        "$APP_DIR/nginx/filebrowser.conf" \
        | nginx_write "$NGINX_EXTRAS/filebrowser.conf"
    if (( NGINX_DIRTY )); then
        run sudo nginx -t && run sudo systemctl reload nginx
    else
        echo "   nginx unchanged — skipping reload"
    fi
fi

echo
echo "done. open http://<host>/files/"
