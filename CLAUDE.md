# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Five sub-projects deliver a unified "mini-OS" desktop experience on myhost (`192.168.1.10`), exposed publicly at `https://service.example.com/` via Cloudflare Tunnel with Access auth. The root page (`/`) is a desktop-like UI launchable from a Start menu with seven apps: Home Service, Terminal, Browser, Files, Notes, Monitor, and Upload.

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

The root page at `/` is a Windows-style shell:
- **Start button** — always present at the taskbar's left. Clicking it toggles the **Start menu**, a launcher listing seven apps (Home Service, Terminal, Browser, Files, Notes, Monitor, Upload) with icon + description. Picking one opens it. (This replaced the old always-pinned tab bar.) **Home Service** is the old service-list page (`landing/index.html`, served at `/landing.html`) wrapped as a launchable app — it shows the service cards, health dots, and dynamic terminal chips. Its extra service cards (and their health-check targets) are **not** in the repo: they're read at runtime from a host-local, gitignored `~/claude-web-www/services.json` (format in `landing/services.example.json`). The page renders them from a direct `/services.json` fetch (LAN) or a parent `postMessage` relay (tunnel), and `terminal-manager.py` merges each entry's `key`/`health` into `/api/health` so the dots work — keeping personal hostnames/IPs out of git.
- **Taskbar apps** — only *opened* apps get a button (Windows-style), each with a close (×). Multiple apps can be open at once; the focused one is highlighted with a per-app accent underline. The set of open apps and the active one are persisted **server-side** via `GET/POST /api/desktop` (file `~/.local/share/desktop-state.json`) so phone and computer see the same desktop. Restored on every load; on a fresh state with nothing open the Start menu auto-opens.
- **App frames** — each app is a full-viewport iframe, **created** on first open but only `src`-loaded on first activation (`loadIfNeeded`) so the inner content always measures the real viewport (otherwise xterm.js / FitAddon initialise at 0×0 and the terminal renders truncated). Closed apps are **removed from the DOM** (true unload). All iframes carry `allow="clipboard-read; clipboard-write"` for cross-iframe clipboard.
- **Status bar** — live system stats updated every 5s via `/api/system/status`: CPU% + temp, MEM used/total, GPU% + temp, VRAM used/total. Rendered in a fixed-width CSS grid (`ch`-sized columns + `tabular-nums`) so labels don't shift sideways as values change digit-count. CPU temp from `k10temp` (Tctl), GPU temp from `amdgpu` (edge). When the GPU driver locks sysfs during heavy compute (EBUSY), util/temp/power **fall back to parsing `/sys/kernel/debug/dri/N/amdgpu_pm_info`** (manager already runs as root) so the numbers stay populated. The full 1/5/15-minute load average is shown only in the Monitor app's CPU card title.
- **Logout button** — taskbar far right, links to `/cdn-cgi/access/logout` (Cloudflare Access).
- Relays `/api/health` (to the Monitor and Home Service apps) and `/api/terminals/status` (to Home Service) via `postMessage`, only when those apps are open — required for the Cloudflare tunnel where an iframe's own fetches don't carry the Access cookie, so the parent fetches and forwards.
- Listens for `postMessage` from the terminal app to open a clicked URL in the Browser app (launching Browser if it isn't already open). Also handles `open-files-at` (from the Upload app) to deep-link the Files app at a given path.
- **Mobile** — viewport meta is pinned (`user-scalable=no`) since iOS pinch-zoom is page-wide and once stuck can't be reliably reset; each app handles its own zoom internally (xpra zooms the canvas, Monitor and FileBrowser have their own responsive layouts). Body uses `100svh` so the taskbar stays in the always-visible region under the URL bar. The taskbar is horizontally scrollable when narrow, the Start menu spans the screen, and `monitor.html`'s 736px breakpoint collapses its two-column grid into a single scrollable column. xterm.js auto-focus is **skipped on touch devices** so auto-switching into Terminal doesn't pop up the on-screen keyboard.

### Shared nginx

One nginx site at `/etc/nginx/sites-available/claude-web` (`listen 80 default_server`). The terminal project owns this file. A `map $uri $term_port` directive (generated for 1..50) routes `/tN/` to port `7680+N` via a single regex location block. Sibling projects extend via `include /etc/nginx/snippets/claude-extras.d/*.conf`.

### Terminal stack

**Dynamic provisioning** — terminals are created/destroyed on demand via a manager API, not pre-provisioned.

Services:
- `claude-web-manager.service` — Python HTTP server on `127.0.0.1:7680` (runs as root). Manages terminal lifecycle and provides system status. Endpoints:
  - Terminal: `POST /api/terminals/{n}/start|stop`, `GET /api/terminals/status`
  - System: `GET /api/system/status` (CPU + per-core, MEM, GPU, VRAM, load_avg, etc.), `GET /api/health`
  - Browser: `POST /api/browser/open` (validated URL → remote Chromium via the xpra display)
  - Notes: `GET/POST /api/notes` (`~/.local/share/desktop-notes.md`)
  - Desktop state: `GET/POST /api/desktop` (`~/.local/share/desktop-state.json` — `{open: [appId,...], active: appId}`, shared between phone and computer)
  - Upload: `POST /api/upload` (streaming multipart parser, writes into `UPLOAD_DIR`, default `~/Uploads`), `GET /api/upload/list`, `POST /api/upload/clear`
- `claude-web-session@N.service` — `claude-session serve N` (Python daemon holding bash in a PTY, started on demand)
- `claude-web-ttyd@N.service` — ttyd on `127.0.0.1:$((7680+N))`, base path `/tN/` (started on demand)

nginx proxies `/tN/` to the corresponding loopback port via the `map`-based regex location. `sub_filter` injects scrollback config, clipboard polyfill, and a `window.open` override that sends URL clicks to the embedded Chromium browser via `/api/browser/open`.

`claude-session` is a custom lightweight replacement for tmux that passes terminal output through transparently (no screen repainting), enabling xterm.js's 50k-line scrollback buffer. It records output in a 256KB ring buffer and replays it on reconnect so the screen state is preserved. Typing `exit` respawns a fresh shell within ~1s; ttyd's `reconnect=3` auto-reconnects the browser tab.

A tabbed UI at `/terminals/` (`terminal/terminals.html`) manages terminal tabs with add (+), close (x, stops the service), drag-reorder, and double-click-to-rename. Tab state persists in localStorage. Closing a tab kills the terminal for a clean slate; clicking "+" starts a fresh instance. Switching tabs auto-focuses the xterm.js terminal via `postMessage` so the cursor is ready for typing.

### Browser stack

One systemd service:
- `claude-browser-xpra` — xpra `start-desktop :99` with built-in HTML5 client on loopback:14500

xpra handles the virtual X display (Xorg + dummy video driver for RANDR), window management (matchbox in kiosk mode), browser launching (via `browser-loop.sh` wrapper for auto-restart), and the HTML5 client + WebSocket serving. The display dynamically resizes to match the client's browser viewport. Clipboard is handled natively by xpra. xpra is installed from the xpra.org apt repo. `--sharing=yes` lets multiple clients (e.g. desktop + phone) view the same session at once; `XPRA_PING_TIMEOUT=20` (env in the unit) evicts dead clients faster than the 60s default.

nginx proxies `/browser/` to xpra's HTTP/WebSocket port with `sub_filter` patches: CSS pins `#screen` to the viewport via `z-index` (hiding xpra's toolbar/login UI and window-decoration chrome like `.windowhead`/`.window-title` without removing keyboard capture elements like `#pasteboard`), and loads `xpra-patches.js` for mouse offset correction, scroll fix, and **mobile touch handling**. The patches JS file is served from the web root and wrapped in `try/catch` for graceful degradation on xpra updates. A separate regex location caches (`max-age=86400`) and gzips xpra's ~2.1MB HTML5 client assets, which xpra otherwise serves uncompressed and `no-store` — the main fix for slow first loads over the tunnel. See `docs/browser.md`.

**Mobile touch in xpra-patches.js** — the parent desktop disables iOS pinch-zoom, so all touch gestures are interpreted inside the iframe. A single capture-phase set of `touchstart`/`touchmove`/`touchend` listeners on `window` (xpra binds on `#screen` so we must run first) routes gestures by finger count:
- **1-finger tap (< 10px movement)** → synthetic `mousedown`/`mouseup`/`click` dispatched on the canvas inside `#screen` so xpra forwards a click to the remote.
- **1-finger drag** → page scroll: dispatches synthetic `wheel` events on the canvas; finger pixels are accumulated into `SCROLL_TICK` chunks (default 33) so scroll speed roughly matches the finger.
- **2-finger pinch** → CPU zoom: each `PINCH_STEP` (40 px) of spread/contract fires a synthetic `Ctrl+=` / `Ctrl+-` keystroke on `document` (xpra forwards these to remote Chromium, which interprets them as native zoom). Explicit `−/⟲/+` zoom buttons live at lower-left for discoverability.
- **On-screen keyboard** — xpra's `.simple-keyboard` is hidden by default; a floating `⌨` chip at bottom-right toggles it, morphing into a red "✕ Hide keyboard" pill measured to sit flush above the keyboard when open. We can't detect taps on remote `<input>`s (the screen is a canvas) so auto-showing on every tap was too aggressive — manual toggle is the trade-off.

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
- **Mobile (≤736px)** — the header toolbar uses `flex-wrap: wrap` so every action button is visible across multiple rows instead of being clipped or hidden behind a `…` overflow trigger; `#dropdown` is forced to render inline (not as a popup) and the more-button is hidden. FileBrowser's stock bottom-floating selection bar (`#file-selection`) and the long-press `.context-menu` are hidden globally — every action already lives in the top toolbar so the popups are redundant. nginx sub_filter loads `filebrowser-patches.js` with a `?vN` cache-buster bumped whenever the CSS changes.

### Notes

A persistent scratchpad at `/notes.html`. Auto-saves 800ms after typing, supports Tab and Cmd+S. Content stored at `~/.local/share/desktop-notes.md`, managed via `GET/POST /api/notes` on the manager API. No external service — just a static HTML page + the existing API server.

### Upload

A quick-sync drop zone at `/upload.html` — useful for getting photos off a phone fast. Tap-to-pick fires the OS picker (iOS opens the photo gallery / files / camera); drag-and-drop works on desktop. Files upload **sequentially**, one XHR per file, so each item in the queue shows its own live percentage badge (0 % → 100 % → ✓ Done / Failed) while the top bar shows aggregate progress. Below the queue, an **In folder** panel lists files currently in `UPLOAD_DIR` (newest first) with Refresh and Clear-all controls, refreshed after every successful upload. An **Open in Files** button deep-links the Files app at the upload folder via an `open-files-at` `postMessage` to the parent desktop. Default destination is `~/Uploads/` (override with `UPLOAD_DIR` env on the manager unit); files are chowned to `APP_USER` after save. nginx's `/api/` location sets `client_max_body_size 5G` and `proxy_request_buffering off` so multi-GB uploads stream through. The manager's multipart parser is hand-rolled and streaming (does NOT spool to temp via `cgi.FieldStorage`).

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
- System status API auto-detects the discrete GPU by picking the card with the most VRAM. CPU temp from `k10temp` (hwmon), GPU temp from `amdgpu` edge sensor (hwmon). During heavy GPU compute, the driver locks sysfs files (`EBUSY`); util/temp/power then fall back to parsing `/sys/kernel/debug/dri/N/amdgpu_pm_info` ("GPU Load", "GPU Temperature", "W (average SoC|GPU)") so the numbers stay populated. The manager runs as root, which is required for debugfs (0700)
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
- Desktop iframes get their `src` set on first activation (`loadIfNeeded`), not at iframe-creation time. ttyd inside an iframe whose ancestor is `display:none` initialises xterm.js with a 0×0 viewport, leading to truncated history that only a refresh fixes; deferring the `src` lets the inner content measure the real viewport on the first paint
- `/api/upload` uses a hand-rolled streaming multipart parser (`_BoundaryReader` + `_iter_multipart_files`). Reads from `self.rfile` are capped by `_LimitedReader(rfile, Content-Length)` because once the body is exhausted, a bare `rfile.read(n)` blocks forever on a keep-alive socket waiting for n more bytes
- iOS pinch-zoom is page-wide and irreversibly sticky once activated, so the desktop shell's viewport meta uses `user-scalable=no,maximum-scale=1`; per-app zooming (xpra canvas, FileBrowser UI) is the inner app's responsibility. Each app's iframe handles its own scroll on `100svh` body so the taskbar stays in the always-visible viewport region
- xpra's HTML5 client renders its own window chrome (`.windowhead`/`.window-title`/`.title-bar`) where the WM name ("matchbox") would otherwise be visible — these selectors are added to the CSS hide list in the `/browser/` nginx sub_filter
