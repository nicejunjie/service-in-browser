#!/usr/bin/env bash
# One-command deploy for claude-browser: a remote browser viewable from any
# browser via xpra's HTML5 client, persistent across disconnects.
#
# Architecture (all on myhost, mostly loopback):
#   xpra start-desktop :DISPLAY_NUM (X server + HTML5 client + WebSocket)
#        └── browser-loop.sh (chromium with auto-restart)
#                              ^
#                              |
#         nginx /browser/ ─────+
#
# Knobs (env vars):
#   APP_USER       system user the X session runs as           (default: invoking user)
#   APP_DIR        where the templates live                    (default: script dir)
#   DISPLAY_NUM    X display number                            (default 99)
#   XPRA_PORT      xpra WebSocket+HTML5 port (loopback)        (default 14500)
#   BROWSER_CMD    full command for the browser                (default: auto-detect chromium/firefox)
#   INSTALL_DEPS   install xpra from xpra.org repo             (default 1)
#   INSTALL_SYSTEMD render & enable systemd unit               (default 1)
#   INSTALL_NGINX  drop the location snippet                   (default 1)
#   DRY_RUN        print actions without executing             (default 0)

set -euo pipefail

APP_USER="${APP_USER:-${SUDO_USER:-$(id -un)}}"
APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
APP_UID="$(id -u "$APP_USER")"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
XPRA_PORT="${XPRA_PORT:-14500}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
INSTALL_SYSTEMD="${INSTALL_SYSTEMD:-1}"
INSTALL_NGINX="${INSTALL_NGINX:-1}"
DRY_RUN="${DRY_RUN:-0}"
LOOP_SCRIPT="/usr/local/lib/claude-browser/browser-loop.sh"

for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        --help|-h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

if ! id "$APP_USER" >/dev/null 2>&1; then
    echo "APP_USER '$APP_USER' does not exist" >&2; exit 1
fi
if ! [ -d "$APP_DIR/systemd" ]; then
    echo "templates not found under APP_DIR=$APP_DIR" >&2; exit 1
fi

run() {
    if (( DRY_RUN )); then printf '+ %s\n' "$*"; else "$@"; fi
}
write_root() {
    local dest="$1"
    if (( DRY_RUN )); then echo "+ write -> $dest"; sed 's/^/    | /'
    else sudo tee "$dest" >/dev/null
    fi
}

# Auto-install Chromium (snap) when nothing is present and we're allowed to —
# the manager's /api/browser/open expects the snap-confined xpra-profile path,
# so snap chromium is the supported browser. (Gated by INSTALL_DEPS.)
if [ -z "${BROWSER_CMD:-}" ] && [ "${INSTALL_DEPS}" = 1 ] \
   && ! [ -x /snap/bin/chromium ] && ! [ -x /snap/bin/firefox ] \
   && ! command -v firefox-esr >/dev/null 2>&1 && ! command -v epiphany >/dev/null 2>&1 \
   && command -v snap >/dev/null 2>&1; then
    echo "== installing chromium (snap) =="
    run sudo snap install chromium
fi

# Pick a browser if not overridden.
if [ -z "${BROWSER_CMD:-}" ]; then
    if [ -x /snap/bin/chromium ]; then
        BROWSER_CMD="/snap/bin/chromium --no-first-run --no-default-browser-check --restore-last-session --start-maximized --user-data-dir=$APP_HOME/snap/chromium/common/xpra-profile"
    elif [ -x /snap/bin/firefox ]; then
        BROWSER_CMD="/snap/bin/firefox --no-remote"
    elif command -v firefox-esr >/dev/null 2>&1; then
        BROWSER_CMD="$(command -v firefox-esr) --no-remote"
    elif command -v epiphany >/dev/null 2>&1; then
        BROWSER_CMD="$(command -v epiphany)"
    else
        echo "no browser found; set BROWSER_CMD or install chromium/firefox/epiphany" >&2
        exit 1
    fi
fi

cat <<EOF
claude-browser install (xpra)
  user          : $APP_USER (uid $APP_UID)
  app dir       : $APP_DIR
  display       : :$DISPLAY_NUM
  xpra port     : $XPRA_PORT (loopback)
  browser cmd   : $BROWSER_CMD
  deps          : $INSTALL_DEPS    systemd: $INSTALL_SYSTEMD    nginx: $INSTALL_NGINX
  dry run       : $DRY_RUN
EOF
echo

# 1. Dependencies ------------------------------------------------------------
if (( INSTALL_DEPS )); then
    echo "== adding xpra.org repository =="
    if [ ! -f /usr/share/keyrings/xpra.asc ]; then
        run sudo wget -qO /usr/share/keyrings/xpra.asc https://xpra.org/xpra.asc
    else
        echo "   GPG key already present"
    fi
    if [ ! -f /etc/apt/sources.list.d/xpra.sources ]; then
        CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")"
        DEB_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
        cat <<REPO_EOF | write_root /etc/apt/sources.list.d/xpra.sources
Types: deb
URIs: https://xpra.org
Suites: $CODENAME
Components: main
Signed-By: /usr/share/keyrings/xpra.asc
Architectures: $DEB_ARCH
REPO_EOF
    else
        echo "   apt source already present"
    fi

    echo "== installing xpra =="
    run sudo apt-get update -qq
    run sudo apt-get install -y xpra xserver-xorg-video-dummy matchbox-window-manager
    # Disable xpra's built-in socket activation (conflicts with our own unit)
    if systemctl is-enabled xpra-server.socket >/dev/null 2>&1; then
        run sudo systemctl disable --now xpra-server.socket
    fi
    # Allow non-console users to run Xorg (needed for the dummy video driver)
    if grep -q 'allowed_users=console' /etc/X11/Xwrapper.config 2>/dev/null; then
        run sudo sed -i 's/allowed_users=console/allowed_users=anybody/' /etc/X11/Xwrapper.config
    fi
    # Allow uinput access for precise wheel scrolling
    if [ ! -f /etc/udev/rules.d/99-uinput.rules ]; then
        echo 'KERNEL=="uinput", MODE="0666"' | write_root /etc/udev/rules.d/99-uinput.rules
    fi
fi

# 2. Stop legacy VNC services if present -------------------------------------
echo "== cleaning up legacy VNC services (if any) =="
for legacy in claude-browser-app claude-browser-novnc \
              claude-browser-wm claude-browser-xserver; do
    if systemctl list-unit-files "${legacy}.service" >/dev/null 2>&1; then
        run sudo systemctl disable --now "${legacy}.service" 2>/dev/null || true
        run sudo rm -f "/etc/systemd/system/${legacy}.service"
    fi
done

# 3. Browser loop script -----------------------------------------------------
echo "== installing browser loop script =="
run sudo install -d -m 0755 "$(dirname "$LOOP_SCRIPT")"
sed -e "s|@BROWSER_CMD@|$BROWSER_CMD|g" \
    "$APP_DIR/browser-loop.sh" | write_root "$LOOP_SCRIPT"
run sudo chmod 0755 "$LOOP_SCRIPT"

# 4. systemd unit ------------------------------------------------------------
if (( INSTALL_SYSTEMD )); then
    echo "== installing systemd unit =="
    sed \
        -e "s|@APP_USER@|$APP_USER|g" \
        -e "s|@APP_HOME@|$APP_HOME|g" \
        -e "s|@APP_UID@|$APP_UID|g" \
        -e "s|@DISPLAY_NUM@|$DISPLAY_NUM|g" \
        -e "s|@XPRA_PORT@|$XPRA_PORT|g" \
        -e "s|@LOOP_SCRIPT@|$LOOP_SCRIPT|g" \
        "$APP_DIR/systemd/claude-browser-xpra.service" \
        | write_root /etc/systemd/system/claude-browser-xpra.service
    run sudo systemctl daemon-reload
fi

# 5. HTML5 client default settings -------------------------------------------
# The xpra-html5 package ships its own default-settings.txt; ours tunes the
# client for this deployment (no floating menu, speed-biased encoding). Apt
# upgrades overwrite it — re-running this script restores it.
if [ -d /usr/share/xpra/www ]; then
    echo "== installing HTML5 client default settings =="
    cat "$APP_DIR/default-settings.txt" | write_root /usr/share/xpra/www/default-settings.txt
fi

# 6. nginx snippet -----------------------------------------------------------
if (( INSTALL_NGINX )); then
    echo "== installing nginx snippet =="
    if ! [ -d /etc/nginx/snippets/claude-extras.d ]; then
        echo "   /etc/nginx/snippets/claude-extras.d does not exist —"
        echo "   re-run claude-web's install.sh first so the include path is wired up." >&2
        exit 1
    fi
    # Deploy xpra patches JS to web root (served as static file at /xpra-patches.js)
    LANDING_DIR="$(getent passwd "$APP_USER" | cut -d: -f6)/claude-web-www"
    run sudo install -m 0644 "$APP_DIR/xpra-patches.js" "$LANDING_DIR/xpra-patches.js"
    sed -e "s|@XPRA_PORT@|$XPRA_PORT|g" \
        "$APP_DIR/nginx/browser.conf" \
        | write_root /etc/nginx/snippets/claude-extras.d/browser.conf
    run sudo nginx -t
    run sudo systemctl reload nginx
fi

# 7. Enable & start ----------------------------------------------------------
if (( INSTALL_SYSTEMD )); then
    echo "== enabling and starting xpra =="
    run sudo systemctl enable --now claude-browser-xpra.service
fi

echo
echo "done. open:"
echo "  http://<host>/browser/"
