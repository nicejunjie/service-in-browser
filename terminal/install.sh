#!/usr/bin/env bash
# One-command deploy for claude-web: persistent ttyd terminals behind nginx.
#
# Usage:
#   ./install.sh                  # full install with defaults
#   ./install.sh --dry-run        # show what would happen, change nothing
#
# Configurable via env vars (all optional):
#   MAX_INSTANCES    max terminal slots in nginx map             (default 50)
#   APP_USER         system user that owns the shells            (default: invoking user)
#   APP_DIR          where ttyd-run.sh lives                     (default: script dir)
#   BASE_PORT        loopback port base; tN -> BASE_PORT+N       (default 7680)
#   NGINX_SITE_NAME  filename under sites-available              (default claude-web)
#   LANDING_DIR      where the landing index.html goes           (default ~APP_USER/claude-web-www)
#   INSTALL_DEPS     install ttyd/nginx via apt                  (default 1)
#   INSTALL_SYSTEMD  render & enable systemd units               (default 1)
#   INSTALL_NGINX    write & enable nginx site                   (default 1)
#   SCROLLBACK       xterm.js scrollback lines                   (default 50000)
#   INSTALL_LANDING  write landing page (1=skip if exists, force=overwrite, 0=off) (default 0)
#   DRY_RUN          print actions without executing them        (default 0)

set -euo pipefail

MAX_INSTANCES="${MAX_INSTANCES:-50}"
APP_USER="${APP_USER:-${SUDO_USER:-$(id -un)}}"
APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BASE_PORT="${BASE_PORT:-7680}"
NGINX_SITE_NAME="${NGINX_SITE_NAME:-claude-web}"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
LANDING_DIR="${LANDING_DIR:-$APP_HOME/claude-web-www}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
INSTALL_SYSTEMD="${INSTALL_SYSTEMD:-1}"
INSTALL_NGINX="${INSTALL_NGINX:-1}"
SCROLLBACK="${SCROLLBACK:-50000}"
INSTALL_LANDING="${INSTALL_LANDING:-0}"
DRY_RUN="${DRY_RUN:-0}"

for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        --help|-h)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

if ! id "$APP_USER" >/dev/null 2>&1; then
    echo "APP_USER '$APP_USER' does not exist on this system" >&2
    exit 1
fi
if ! [ -f "$APP_DIR/ttyd-run.sh" ]; then
    echo "ttyd-run.sh not found under APP_DIR=$APP_DIR" >&2
    exit 1
fi

run() {
    if (( DRY_RUN )); then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}

write_root() {
    local dest="$1"
    if (( DRY_RUN )); then
        echo "+ write -> $dest"
        sed 's/^/    | /'
    else
        sudo tee "$dest" >/dev/null
    fi
}

cat <<EOF
claude-web install
  max instances : $MAX_INSTANCES       (ports $((BASE_PORT+1))..$((BASE_PORT+MAX_INSTANCES)))
  user          : $APP_USER
  app dir       : $APP_DIR
  nginx site    : $NGINX_SITE_NAME
  landing dir   : $LANDING_DIR
  deps          : $INSTALL_DEPS    systemd: $INSTALL_SYSTEMD    nginx: $INSTALL_NGINX    landing: $INSTALL_LANDING
  dry run       : $DRY_RUN
EOF
echo

# 1. Dependencies ------------------------------------------------------------
if (( INSTALL_DEPS )); then
    echo "== installing apt packages =="
    run sudo apt-get update -qq
    run sudo apt-get install -y ttyd nginx acl
fi

# 2. ttyd-run.sh executable bit ---------------------------------------------
run chmod +x "$APP_DIR/ttyd-run.sh" "$APP_DIR/claude-session"

# 3. systemd unit templates --------------------------------------------------
if (( INSTALL_SYSTEMD )); then
    echo "== installing systemd unit templates =="
    for unit in claude-web-session@.service claude-web-ttyd@.service; do
        rendered="$(sed \
            -e "s|@APP_USER@|$APP_USER|g" \
            -e "s|@APP_DIR@|$APP_DIR|g" \
            "$APP_DIR/systemd/$unit")"
        echo "$rendered" | write_root "/etc/systemd/system/$unit"
    done

    # Terminal manager API
    rendered="$(sed \
        -e "s|@APP_DIR@|$APP_DIR|g" \
        -e "s|@BASE_PORT@|$BASE_PORT|g" \
        "$APP_DIR/systemd/claude-web-manager.service")"
    echo "$rendered" | write_root "/etc/systemd/system/claude-web-manager.service"

    run sudo systemctl daemon-reload
fi

# 4. nginx config ------------------------------------------------------------
if (( INSTALL_NGINX )); then
    echo "== installing nginx config =="

    # 4a. $connection_upgrade map (only if not defined elsewhere)
    if sudo grep -rqsE 'map[[:space:]]+\$http_upgrade[[:space:]]+\$connection_upgrade' /etc/nginx/; then
        echo "   connection_upgrade map already defined elsewhere — skipping"
    else
        cat "$APP_DIR/nginx/claude-web-upgrade.conf" \
            | write_root "/etc/nginx/conf.d/claude-web-upgrade.conf"
    fi

    # 4b. Build port map for terminal routing
    map_entries=""
    for i in $(seq 1 "$MAX_INSTANCES"); do
        map_entries+="    ~^/t${i}(/|\$)  $((BASE_PORT + i));
"
    done

    site_config="# Terminal port map: /tN/ -> port BASE_PORT+N
map \$uri \$term_port {
    default \"\";
$map_entries}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root $LANDING_DIR;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
        add_header Cache-Control 'no-cache, no-store' always;
    }

    location = /terminals { return 301 /terminals/; }
    location = /terminals/ {
        add_header Cache-Control 'no-cache, no-store' always;
        rewrite ^ /terminals.html break;
    }

    # Terminal manager & system status API
    location /api/ {
        proxy_pass http://127.0.0.1:$BASE_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        client_max_body_size 5G;       # allow large /api/upload posts
        proxy_request_buffering off;   # stream upload body to the manager
        proxy_read_timeout 3600;

        # Status JSON is a few KB and polled every few seconds; gzip shrinks
        # it ~4x (nginx won't gzip proxied responses without gzip_proxied).
        gzip on;
        gzip_proxied any;
        gzip_types application/json;
        gzip_min_length 256;
    }

    # Dynamic terminal routing: /tN/ -> port from map
    location ~ ^/t(\d+)/(.*)$ {
        proxy_pass http://127.0.0.1:\$term_port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Accept-Encoding \"\";
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;

        # ttyd's page is a single ~240KB HTML (xterm.js inlined), served
        # uncompressed because sub_filter needs a plain upstream body. Re-gzip
        # the filtered output to the client — on slow/mobile links the
        # uncompressed page was the terminal's whole time-to-content.
        # WebSocket frames are unaffected.
        gzip on;
        gzip_proxied any;
        gzip_types text/html text/javascript application/javascript text/css application/json;
        gzip_min_length 1024;

        sub_filter 'fontSize:13,' 'fontSize:13,scrollback:$SCROLLBACK,';
        sub_filter '</head>' '<script>(function(){var isMac=/Mac/.test(navigator.platform);var isTouch=window.matchMedia&&window.matchMedia(\"(pointer: coarse)\").matches;var EXP=location.search.indexOf(\"kbdexp\")>=0;var blockTa=true;if(isTouch&&!EXP){document.addEventListener(\"focusin\",function(e){var t=e.target;if(blockTa&&t&&t.classList&&t.classList.contains(\"xterm-helper-textarea\"))t.blur()},true)}function copySelection(){var t=window.term;if(!t||!t.hasSelection())return;var s=t.getSelection();if(!s)return;var ta=document.querySelector(\".xterm-helper-textarea\");if(ta){ta.value=s;blockTa=false;ta.select();document.execCommand(\"copy\");blockTa=true;ta.value=\"\"}}var check=setInterval(function(){if(!window.term)return;clearInterval(check);var t=window.term;t.onSelectionChange(function(){if(t.hasSelection())copySelection()});t.attachCustomKeyEventHandler(function(e){if(e.type!==\"keydown\")return true;var mod=isMac?e.metaKey:e.ctrlKey;if(!mod||e.shiftKey||e.altKey)return true;if(isMac&&e.ctrlKey)return true;if(e.key===\"c\"&&t.hasSelection()){copySelection();t.clearSelection();return false}if(e.key===\"v\"){var ta=document.querySelector(\".xterm-helper-textarea\");if(ta){ta.value=\"\";ta.focus()}return true}return true})},100);document.addEventListener(\"auxclick\",function(e){if(e.button!==1)return;e.preventDefault();var ta=document.querySelector(\".xterm-helper-textarea\");if(ta){ta.value=\"\";ta.focus()}});function sendToBrowser(u){fetch(\"/api/browser/open\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({url:u})});try{window.top.postMessage({type:\"switch-to-browser\"},\"*\")}catch(e){}}var wo=window.open;window.open=function(u){if(u&&(u.startsWith(\"http://\")||u.startsWith(\"https://\"))){sendToBrowser(u);return null}if(!u){return{opener:null,location:Object.defineProperty({},\"href\",{set:function(v){sendToBrowser(v)}})}}return wo.apply(this,arguments)}})();(function(){var busy=false,RK=\"ttyd-recon-ts\";function fireEnter(){var ta=document.querySelector(\".xterm-helper-textarea\");if(ta){[\"keydown\",\"keyup\"].forEach(function(ty){ta.dispatchEvent(new KeyboardEvent(ty,{key:\"Enter\",code:\"Enter\",keyCode:13,which:13,bubbles:true,cancelable:true}))})}}function stuck(){var b=document.body;if(!b)return false;var d=b.querySelectorAll(\"div\");for(var i=0;i<d.length;i++){var t=d[i].textContent||\"\";if(t.indexOf(\"Press\")!==-1&&t.indexOf(\"Reconnect\")!==-1)return true}return false}function handle(){if(busy)return;busy=true;fireEnter();setTimeout(function(){if(stuck()){var now=Date.now(),last=+(sessionStorage.getItem(RK)||0);if(now-last>8000){sessionStorage.setItem(RK,now);location.reload();return}}busy=false},1200)}function check(n){var t=(n&&n.textContent)||\"\";if(t.indexOf(\"Reconnect\")!==-1&&t.indexOf(\"Press\")!==-1)handle()}var obs=new MutationObserver(function(ms){ms.forEach(function(m){if(m.type===\"characterData\")check(m.target.parentNode);(m.addedNodes||[]).forEach(check)})});function startObs(){if(!document.body){setTimeout(startObs,50);return}obs.observe(document.body,{childList:true,subtree:true,characterData:true});if(stuck())handle()}startObs()})();(function(){function sendRaw(d){var t=window.term;if(!t)return;try{var cs=t._core&&t._core.coreService;if(cs&&cs.triggerDataEvent){cs.triggerDataEvent(d,true);return}}catch(_){}try{t.paste(d)}catch(_){}}window.addEventListener(\"message\",function(e){var m=e.data;if(!m)return;if(m.type===\"kbd-char\"&&typeof m.ch===\"string\")sendRaw(m.ch);else if(m.type===\"kbd-key\"){if(m.key===\"Enter\")sendRaw(String.fromCharCode(13));else if(m.key===\"Backspace\")sendRaw(String.fromCharCode(127));else if(m.key===\"Tab\")sendRaw(String.fromCharCode(9))}},false)})();</script><script src=\"/term-x-patch.js?v2\"></script></head>';
        sub_filter_once off;
    }
    location ~ ^/t(\d+)$ { return 301 \$scheme://\$host/t\$1/; }

    # Sibling projects (e.g. claude-browser) drop /etc/nginx/snippets/claude-extras.d/*.conf
    # to add their own location blocks without modifying this file.
    include /etc/nginx/snippets/claude-extras.d/*.conf;
}
"
    run sudo install -d -m 0755 /etc/nginx/snippets/claude-extras.d
    echo "$site_config" | write_root "/etc/nginx/sites-available/$NGINX_SITE_NAME"

    # 4c. Disable any other default_server site that would clash
    if [ -L "/etc/nginx/sites-enabled/default" ] \
        && [ "$(readlink -f /etc/nginx/sites-enabled/default 2>/dev/null || true)" \
             != "$(readlink -f /etc/nginx/sites-available/$NGINX_SITE_NAME 2>/dev/null || true)" ]; then
        echo "   disabling /etc/nginx/sites-enabled/default (was: $(readlink /etc/nginx/sites-enabled/default))"
        run sudo rm -f /etc/nginx/sites-enabled/default
    fi
    run sudo ln -sfn "/etc/nginx/sites-available/$NGINX_SITE_NAME" \
                     "/etc/nginx/sites-enabled/$NGINX_SITE_NAME"

    # Install terminals.html to the landing dir for /terminals/ route
    if [ -f "$APP_DIR/terminals.html" ]; then
        run sudo install -o "$APP_USER" -g "$APP_USER" -m 0644 \
            "$APP_DIR/terminals.html" "$LANDING_DIR/terminals.html"
    fi

    # Experimental single-terminal page (Terminal X app) — served as a static
    # file by `location /`; loads /t50/?kbdexp=1 to enable the dictation patch.
    if [ -f "$APP_DIR/term-x.html" ]; then
        run sudo install -o "$APP_USER" -g "$APP_USER" -m 0644 \
            "$APP_DIR/term-x.html" "$LANDING_DIR/term-x.html"
    fi
    # Its dictation patch (loaded into /tN/ via the sub_filter <script src>).
    if [ -f "$APP_DIR/term-x-patch.js" ]; then
        run sudo install -o "$APP_USER" -g "$APP_USER" -m 0644 \
            "$APP_DIR/term-x-patch.js" "$LANDING_DIR/term-x-patch.js"
    fi

    run sudo nginx -t
    run sudo systemctl reload nginx
fi

# 5. Landing page ------------------------------------------------------------
write_landing=0
case "$INSTALL_LANDING" in
    1)
        if [ -e "$LANDING_DIR/index.html" ]; then
            echo "== landing page already at $LANDING_DIR/index.html — skipping =="
        else
            write_landing=1
        fi ;;
    force) write_landing=1 ;;
    0) : ;;
    *) echo "INSTALL_LANDING must be 0, 1, or force (got: $INSTALL_LANDING)" >&2; exit 1 ;;
esac
if (( write_landing )); then
    echo "== writing landing page =="
    run sudo install -d -o "$APP_USER" -g "$APP_USER" -m 0755 "$LANDING_DIR"
    p="$LANDING_DIR"
    while p="$(dirname "$p")" && [ "$p" != "/" ] && [ -n "$p" ]; do
        if ! sudo -u www-data test -x "$p" 2>/dev/null; then
            run sudo setfacl -m u:www-data:x "$p"
        fi
    done
fi

# 6. Enable & start services -------------------------------------------------
if (( INSTALL_SYSTEMD )); then
    echo "== enabling terminal manager =="
    run sudo systemctl enable --now claude-web-manager.service

    # Start terminal 1 if nothing is running
    if ! systemctl is-active --quiet claude-web-ttyd@1.service 2>/dev/null; then
        echo "== starting terminal 1 =="
        run sudo systemctl start claude-web-session@1.service claude-web-ttyd@1.service
    fi

    # Stop and disable any pre-provisioned instances beyond what's running
    echo "== disabling pre-provisioned instances (now on-demand) =="
    for i in $(seq 1 99); do
        if systemctl is-enabled --quiet "claude-web-ttyd@$i.service" 2>/dev/null; then
            run sudo systemctl disable "claude-web-ttyd@$i.service" "claude-web-session@$i.service" 2>/dev/null || true
        fi
    done
fi

echo
echo "done. open http://<host>/terminals/"
