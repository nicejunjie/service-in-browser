# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Five sub-projects deliver a unified "mini-OS" desktop experience on myhost (`192.168.1.10`), exposed publicly at `https://service.example.com/` via Cloudflare Tunnel with Access auth. The root page (`/`) is a desktop-like UI with five tabs: Home, Terminal, Browser, Files, and Notes.

| Sub-project | URL path | What |
|---|---|---|
| terminal | `/t1/`..`/t50/`, `/terminals/`, `/api/` | Dynamic persistent bash terminals (ttyd + claude-session) + manager API |
| browser | `/browser/` | Persistent Chromium viewable via xpra HTML5 client |
| landing | `/` | Unified desktop UI with tab bar, iframe viewport, and status bar |
| files | `/files/` | FileBrowser file manager rooted at `~` |
| tunnel | — | Cloudflare Tunnel + Access config for public HTTPS |

## Deploy commands

Each sub-project has an idempotent `install.sh`. Order matters on first deploy:

```bash
# 1. Terminal (provisions nginx skeleton with extras include + manager API)
sudo ./terminal/install.sh

# 2. Browser (drops nginx snippet into the extras dir created above)
sudo ./browser/install.sh

# 3. Landing page (desktop UI + file manager)
./landing/install.sh

# 4. Tunnel (installs cloudflared binary; tunnel setup is interactive — see tunnel/README.md)
sudo ./tunnel/install.sh
```

All scripts support `--dry-run` and are configurable via env vars (see script headers).

## Health check

```bash
systemctl status claude-web-manager claude-browser-xpra claude-web-filebrowser
curl -sI http://127.0.0.1/ http://127.0.0.1/t1/ http://127.0.0.1/browser/ http://127.0.0.1/files/
curl -s http://127.0.0.1/api/system/status
curl -s http://127.0.0.1/api/terminals/status
sudo systemctl status cloudflared
```

## Architecture

### Unified desktop (`landing/desktop.html`)

The root page at `/` is a single-page desktop with:
- **Tab bar** — five pinned tabs: Home (orange, loads `/landing.html`), Terminal (green, loads `/terminals/`), Browser (blue, loads `/browser/`), Files (purple, loads `/files/`), Notes (teal, loads `/notes.html`). Each loads its content in a full-viewport iframe.
- **Status bar** — live system stats (CPU% + temp, memory, GPU% + temp, VRAM, uptime, terminal count) updated every 5s via `/api/system/status`. CPU temp from `k10temp` (Tctl), GPU temp from `amdgpu` (edge). When the GPU driver locks sysfs during heavy compute, utilization/temp show `--` while VRAM remains available.
- **Logout button** — upper-right corner, links to `/cdn-cgi/access/logout` (Cloudflare Access).
- All iframes have `allow="clipboard-read; clipboard-write"` for cross-iframe clipboard support.
- Remembers last active tab in localStorage.
- Relays `/api/health` and `/api/terminals/status` to the Home iframe via `postMessage` (required for Cloudflare tunnel where iframe fetches don't carry the Access cookie).
- Listens for `postMessage` from terminal iframes to auto-switch to Browser tab when a URL is opened.
- **Mobile** — a `max-width: 736px` breakpoint makes the bottom tab bar horizontally scrollable (instead of clipping the right-side tabs/stats/logout). `monitor.html` has its own `736px` breakpoint that collapses its two-column grid into a single scrollable column (the desktop layout is `overflow:hidden`, so charts get explicit heights or the canvas collapses to zero). The terminal and xpra-browser tabs are still desktop-oriented on touch.

### Shared nginx

One nginx site at `/etc/nginx/sites-available/claude-web` (`listen 80 default_server`). The terminal project owns this file. A `map $uri $term_port` directive (generated for 1..50) routes `/tN/` to port `7680+N` via a single regex location block. Sibling projects extend via `include /etc/nginx/snippets/claude-extras.d/*.conf`.

### Terminal stack

**Dynamic provisioning** — terminals are created/destroyed on demand via a manager API, not pre-provisioned.

Services:
- `claude-web-manager.service` — Python HTTP server on `127.0.0.1:7680` (runs as root). Manages terminal lifecycle and provides system status. Endpoints: `POST /api/terminals/{n}/start|stop`, `GET /api/terminals/status`, `GET /api/system/status`, `POST /api/browser/open`, `GET/POST /api/notes`, `GET /api/health`.
- `claude-web-session@N.service` — `claude-session serve N` (Python daemon holding bash in a PTY, started on demand)
- `claude-web-ttyd@N.service` — ttyd on `127.0.0.1:$((7680+N))`, base path `/tN/` (started on demand)

nginx proxies `/tN/` to the corresponding loopback port via the `map`-based regex location. `sub_filter` injects scrollback config, clipboard polyfill, and a `window.open` override that sends URL clicks to the embedded Chromium browser via `/api/browser/open`.

`claude-session` is a custom lightweight replacement for tmux that passes terminal output through transparently (no screen repainting), enabling xterm.js's 50k-line scrollback buffer. It records output in a 256KB ring buffer and replays it on reconnect so the screen state is preserved. Typing `exit` respawns a fresh shell within ~1s; ttyd's `reconnect=3` auto-reconnects the browser tab.

A tabbed UI at `/terminals/` (`terminal/terminals.html`) manages terminal tabs with add (+), close (x, stops the service), drag-reorder, and double-click-to-rename. Tab state persists in localStorage. Closing a tab kills the terminal for a clean slate; clicking "+" starts a fresh instance. Switching tabs auto-focuses the xterm.js terminal via `postMessage` so the cursor is ready for typing.

### Browser stack

One systemd service:
- `claude-browser-xpra` — xpra `start-desktop :99` with built-in HTML5 client on loopback:14500

xpra handles the virtual X display (Xorg + dummy video driver for RANDR), window management (matchbox in kiosk mode), browser launching (via `browser-loop.sh` wrapper for auto-restart), and the HTML5 client + WebSocket serving. The display dynamically resizes to match the client's browser viewport. Clipboard is handled natively by xpra. xpra is installed from the xpra.org apt repo. `--sharing=yes` lets multiple clients (e.g. desktop + phone) view the same session at once; `XPRA_PING_TIMEOUT=20` (env in the unit) evicts dead clients faster than the 60s default.

nginx proxies `/browser/` to xpra's HTTP/WebSocket port with `sub_filter` patches: CSS pins `#screen` to the viewport via `z-index` (hiding xpra's toolbar/login UI without removing keyboard capture elements like `#pasteboard`), and loads `xpra-patches.js` for mouse offset correction and scroll fix. The patches JS file is served from the web root and wrapped in `try/catch` for graceful degradation on xpra updates. A separate regex location caches (`max-age=86400`) and gzips xpra's ~2.1MB HTML5 client assets, which xpra otherwise serves uncompressed and `no-store` — the main fix for slow first loads over the tunnel. See `docs/browser.md`.

### File manager

- `claude-web-filebrowser.service` — [FileBrowser](https://filebrowser.org/) on `127.0.0.1:8085`, base URL `/files`, root at `~`, no auth (Cloudflare Access handles public auth).
- nginx snippet at `/etc/nginx/snippets/claude-extras.d/filebrowser.conf` proxies `/files/` to it. The nginx config injects `filebrowser-patches.js` via `sub_filter` on both the exact `/files/` and prefix `/files/*` locations.
- Config stored in `~/.config/filebrowser/filebrowser.db`. Hidden files are hidden by default (toggle in FileBrowser's UI).

**UI patches** (`landing/filebrowser-patches.js`, served from web root):

FileBrowser's icon-only toolbar buttons are enhanced with text labels and an "Open in Browser" action:
- **Text labels** — header and inline `#dropdown` action buttons get column layout (icon above, label below) via injected CSS. Verbose labels are shortened (e.g. "Copy file" → "Copy", "Switch view" → "View").
- **Permanent action buttons** — Browser, Share, Rename, Copy, Move, Delete, Download buttons are always visible in the header toolbar. They are greyed out (25% opacity, non-clickable) when no file/folder is selected, and active when a selection exists. Vue's own conditional buttons are hidden to avoid duplication. The Browser button is only active for files, not folders. When clicked, non-Browser buttons delegate to Vue's hidden original button via programmatic `.click()` — the hiding CSS must not use `pointer-events:none` or the click delegation breaks.
- **"Open in Browser" action** — opens the selected file in the embedded Chromium via `POST /api/browser/open` and auto-switches to the Browser tab via `postMessage`. Also injected into FileBrowser's native right-click context menu (`.context-menu`).
- **MutationObserver** — patches run on every DOM change (with `aria-selected` attribute filter) so labels, button state, and Vue button hiding apply instantly without flicker. A 2s fallback interval covers edge cases.

### Notes

A persistent scratchpad at `/notes.html`. Auto-saves 800ms after typing, supports Tab and Cmd+S. Content stored at `~/.local/share/myhost-notes.md`, managed via `GET/POST /api/notes` on the manager API. No external service — just a static HTML page + the existing API server.

### Landing page (`landing/index.html`)

The old service listing page, preserved at `/landing.html` and loaded in the Home tab. Shows cards for each service with health-check dots. Terminal section dynamically shows chips for each running terminal (fetched from `/api/terminals/status`). Health data is relayed from the parent desktop via `postMessage` to work through the Cloudflare tunnel. All external service links use `target="_blank"` to open in new native tabs (required since the page is inside an iframe).

### URL forwarding (terminal/files → browser)

Clicking a URL in a terminal (Cmd+click / Ctrl+click) or using the "Open in Browser" action in Files opens it in the embedded Chromium. Implementation:
- nginx `sub_filter` injects a `window.open` override into terminal pages
- The override intercepts xterm.js's link handler (which calls `window.open()` then sets `.location.href`) and returns a proxy object
- The proxy sends the URL to `POST /api/browser/open`, which runs `chromium <url>` on the xpra display
- The manager passes `DBUS_SESSION_BUS_ADDRESS` and `--user-data-dir` matching the xpra profile so the URL opens in the correct Chromium instance
- A `postMessage` to the parent desktop auto-switches to the Browser tab
- Files opened from FileBrowser use the `/fileview/` nginx location (alias to `~`) to serve raw files to Chromium

### Tunnel

`cloudflared` maintains an outbound connection to Cloudflare. All traffic for `service.example.com` routes to `localhost:80`. Cloudflare Access handles auth (email PIN + Google). Config lives at `/etc/cloudflared/config.yml` (rendered from `tunnel/config.yml.template`).

## Uninstall

Each sub-project (except landing) has an idempotent `uninstall.sh` that reverses its install. They leave apt packages and user data (browser profile, shell history) in place.

```bash
sudo ./terminal/uninstall.sh          # stops units, removes nginx site
sudo ./browser/uninstall.sh           # stops units, removes nginx snippet
sudo ./tunnel/uninstall.sh            # N/A — uninstall cloudflared manually
```

All support `--dry-run`.

## Key operational commands

```bash
# Terminal operations
curl -X POST http://127.0.0.1/api/terminals/5/start  # start terminal 5
curl -X POST http://127.0.0.1/api/terminals/5/stop   # stop terminal 5
curl http://127.0.0.1/api/terminals/status            # list running terminals
sudo systemctl restart claude-web-manager             # restart manager API

# Browser operations
sudo systemctl restart claude-browser-xpra            # restart xpra + chromium
xpra info :99                                         # session info

# File manager
sudo systemctl restart claude-web-filebrowser         # restart file manager

# System status
curl http://127.0.0.1/api/system/status               # CPU, memory, uptime, GPU
curl http://127.0.0.1/api/health                       # service health checks

# Nginx after config changes
sudo nginx -t && sudo systemctl reload nginx

# Tunnel
sudo journalctl -u cloudflared -f
```

## Which docs to read

- Terminal details (claude-session daemon, ttyd flags, dynamic provisioning, tabbed UI): `docs/terminal.md`
- Browser details (xpra, snap chromium, multi-client): `docs/browser.md`
- Network topology options: `docs/single-port-options.md`
- Tunnel setup walkthrough: `tunnel/README.md`

## Install script conventions

All `install.sh` scripts share the same patterns:
- Idempotent and re-runnable. `--dry-run` (or `-n`) previews without acting.
- Env vars override defaults (e.g. `MAX_INSTANCES=50`, `XPRA_PORT=14500`). See the header comment in each script for the full list.
- Systemd unit files under `*/systemd/` are templates with `@PLACEHOLDER@` tokens (e.g. `@APP_USER@`, `@DISPLAY_NUM@`). install.sh renders them via `sed` and writes to `/etc/systemd/system/`.
- nginx configs under `*/nginx/` follow the same pattern.

## Gotchas

- Snap chromium can't use `--user-data-dir` outside its confinement — the xpra profile lives at `~/snap/chromium/common/xpra-profile`. The `/api/browser/open` handler must pass this profile and `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus` when running `chromium` via `su`, otherwise the URL silently goes nowhere ("Opening in existing browser session" fails without D-Bus, and without `--user-data-dir` it targets the wrong Chromium instance)
- xpra is installed from xpra.org's apt repo (GPG key at `/usr/share/keyrings/xpra.asc`, source at `/etc/apt/sources.list.d/xpra.sources`) — Ubuntu's packaged v3.1.5 is too old (no HTML5 client)
- The browser-loop.sh wrapper (at `/usr/local/lib/claude-browser/browser-loop.sh`) auto-restarts chromium on crash — xpra's `--start-child` only runs the command once
- Desktop page at `~/claude-web-www/index.html` is `landing/desktop.html`; old landing page preserved at `~/claude-web-www/landing.html`
- `www-data` gets traversal on `/home/myuser` via ACL (`setfacl`), preserving the home dir's 0750 mode
- xterm.js scrollback requires `sub_filter` injection in nginx — ttyd 1.7.4's runtime option setter doesn't resize the buffer
- Clipboard in terminals uses a DOM-based copy technique injected via nginx `sub_filter`: on selection change, the selected text is written into xterm.js's helper textarea, selected via `ta.select()`, then copied via `document.execCommand('copy')`. This is the only approach that works inside nested iframes — the async Clipboard API (`navigator.clipboard.writeText`) and `clipboardData.setData()` in copy event handlers are both silently blocked by browsers in iframe contexts. Ctrl+C/Cmd+C with a selection copies instead of sending SIGINT; Ctrl+V/Cmd+V paste is handled natively by the browser
- All desktop iframes use `allow="clipboard-read; clipboard-write"` — without this, clipboard paste into the xpra browser iframe fails
- Terminal iframes in `terminals.html` also need `allow="clipboard-read; clipboard-write"` for clipboard to work through the double-nested iframe chain (desktop → terminals → /tN/)
- `claude-session` attach client clears `ICRNL` from terminal input flags so `\r` (Enter) passes through to TUI apps like Claude Code without being converted to `\n`. Does NOT use full `tty.setraw()` to preserve output post-processing
- xpra CSS uses `z-index` overlay (not `display:none`) to hide the toolbar — hiding body children with `display:none` breaks keyboard input because xpra's `#pasteboard` textarea (used for keyboard capture) must remain in the DOM
- xpra patches (`browser/xpra-patches.js`) are served as a standalone JS file from the web root, wrapped in `try/catch` for graceful degradation if xpra updates change the API
- System status API auto-detects the discrete GPU by picking the card with the most VRAM. CPU temp from `k10temp` (hwmon), GPU temp from `amdgpu` edge sensor (hwmon). During heavy GPU compute, the driver locks sysfs files (`EBUSY`) — utilization and temp gracefully degrade to `--` while VRAM remains readable
- Terminal manager API validates URLs for `/api/browser/open` by rejecting shell metacharacters to prevent command injection
- Terminal instances are dynamic (on-demand via `/api/terminals/`). Systemd template units are not pre-enabled; the manager API starts/stops them. Only `claude-web-manager.service` is enabled at boot
- The `window.open` override in terminal pages intercepts xterm.js link clicks by returning a proxy object with a setter on `.location.href` — this matches xterm.js's pattern of `window.open()` then `obj.location.href = url`
- nginx uses a `map $uri $term_port` directive (generated for 1..50) and one regex location block instead of per-instance location blocks
- FileBrowser config is in `~/.config/filebrowser/filebrowser.db` (set via `filebrowser config set`), not CLI flags
- FileBrowser patches (`landing/filebrowser-patches.js`) are loaded via nginx `sub_filter` injection, not bundled with FileBrowser. The patches hide Vue's conditional action buttons and replace them with permanent always-visible buttons — CSS for these must be scoped to `.fb-permanent` to avoid overriding the `display:none` hiding of Vue's buttons. On desktop widths (>736px), `#dropdown` content renders inline in the header (not as a popup), so dropdown buttons also need label styling
- `landing/install.sh` must run without `sudo` — with `sudo`, `$HOME` resolves to `/root/` and files deploy to the wrong directory
- tunnel's `install.sh` only installs the `cloudflared` binary — tunnel creation and Access setup are interactive (see `tunnel/README.md`)
- xpra is single-client by default — without `--sharing=yes`, opening the Browser tab on a second device evicts the first, and a desktop+phone pair kick each other in a loop so the phone "never loads." Cloudflare-tunnel clients arrive from `127.0.0.1`, so in xpra logs a remote tunnel client appears as a loopback address (not the real client IP)
- xpra's HTML5 client assets are served `no-store` and uncompressed; the `/browser/` nginx snippet adds a regex asset location that caches + gzips them. nginx won't gzip proxied responses without `gzip_proxied any`, and xpra's JS Content-Type is `text/javascript` (not `application/javascript`) — both must be set or compression silently no-ops
