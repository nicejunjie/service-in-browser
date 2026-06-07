# claude-browser (project on myhost)

A persistent web browser running on myhost, viewable from any browser
at `http://192.168.1.10/browser/` (or `https://service.example.com/browser/`
via Cloudflare Tunnel). Same continuity story as the terminals: close
the tab, reopen from any device, same browser, same tabs, same scroll
position.

Project dir: `~/vibe-coding/service-in-browser/browser/`

## What it is

One systemd service running as user `myuser`:

**`claude-browser-xpra.service`** — xpra `start-desktop :99` with:
- **Xorg + dummy video driver** as the virtual display (full RANDR
  support for dynamic resize — the display resolution changes to match
  the client's browser viewport)
- **matchbox-window-manager** in kiosk mode (no titlebar, no desktop —
  chromium fills the entire display)
- **chromium** (snap) via `browser-loop.sh` wrapper for auto-restart
- **Built-in HTML5 client + WebSocket** on `127.0.0.1:14500`

Key xpra flags:
- `--xvfb=Xorg` — uses Xorg with the dummy video driver instead of Xvfb
  (Xvfb doesn't support dynamic RANDR resize)
- `--ws-auth=none` — no xpra authentication (Cloudflare Access handles
  public auth, loopback binding handles LAN security)
- `--resize-display=yes` — allow client to resize the virtual display
- `--input-devices=uinput` — precise input handling
- `--encoding=auto` with speed/quality tuning for LAN use
- `--sharing=yes` — **required** for multiple clients to coexist. Without
  it xpra runs single-client: a new connection evicts the existing one
  ("new client does not wish to share"). With a desktop tab and a phone
  open at once they would otherwise kick each other in a loop, so the
  phone "never loads." Cloudflare-tunnel clients arrive at nginx from
  `127.0.0.1`, so in the logs a tunnel client shows as a loopback address.
- `Environment=XPRA_PING_TIMEOUT=20` (in the unit) — evict a dead/stale
  client after 20s instead of the 60s default, so a freshly opened browser
  doesn't wait on a zombie session from a closed tab/laptop.

## nginx integration

claude-web's site includes `/etc/nginx/snippets/claude-extras.d/*.conf`,
and claude-browser drops `browser.conf` there:

- `location = /browser` → `301` to `/browser/`
- `location /browser/` — reverse-proxy to `127.0.0.1:14500` with WS
  upgrade headers. `proxy_pass` with trailing slash strips the `/browser/`
  prefix so xpra sees clean paths.
- A **regex location** for static assets
  (`^/browser/(.+\.(js|css|wasm|woff2?|...))$`) — placed before the prefix
  block so it wins for asset requests, while the extension-less WebSocket
  path falls through to `/browser/`. It exists to fix slow first loads.

### Asset caching & compression

xpra serves its ~2.1 MB HTML5 client (jQuery, `Client.js`, decode
workers, wasm) with `Cache-Control: no-store` and **uncompressed**, so a
fresh open re-downloaded the whole bundle every time — painfully slow over
the tunnel. The asset location fixes both:

- **Caching** — `proxy_hide_header Cache-Control` + `add_header
  Cache-Control "public, max-age=86400"`. xpra's assets are immutable per
  release, so a day is safe. *Caveat:* after an `apt upgrade` of xpra a
  stale asset could be served for up to a day — hard-refresh once, or drop
  the max-age.
- **Compression** — `gzip on; gzip_proxied any;` (nginx does **not** gzip
  proxied responses without `gzip_proxied`), and `gzip_types` must include
  `text/javascript` — xpra's actual JS Content-Type, not
  `application/javascript`. With it, `jquery.js` goes 290 KB → 104 KB.
- The entry HTML stays `no-store` so the `sub_filter` patches keep running.
- Assets are proxied (not on nginx's filesystem), so `gzip_static`/the
  shipped `.br`/`.gz` files can't be used directly; nginx compresses on
  the fly instead.

### sub_filter patches

nginx injects CSS and JavaScript into the HTML5 client page via
`sub_filter` to fix two xpra client issues:

1. **Mouse offset fix** — xpra's `getMouse()` uses `e.clientX`/`e.clientY`
   (viewport-relative) but the canvas element may not start at viewport
   (0,0) due to xpra's UI elements. The patch overrides `getMouse` to use
   `getBoundingClientRect()` on the canvas, making coordinates relative to
   the actual canvas position. CSS also pins `#screen` to `position:fixed`
   at (0,0) and hides all xpra UI siblings (floating menu, login overlay).

2. **Scroll fix** — xpra's default scroll handler accumulates wheel deltas
   until they reach 120 units (one "click"), which means slow trackpad
   scrolling on macOS produces no response. The patch replaces
   `on_mousescroll` entirely: every wheel event with a non-zero delta
   immediately sends at least one scroll button press/release (button 4/5
   for vertical, 6/7 for horizontal). Larger deltas send proportionally
   more clicks (1 per 30px).

## Snap chromium specifics

On Ubuntu 24.04, `chromium-browser` is snap-only. Snap confinement
**blocks** `--user-data-dir` paths outside the snap's allowed dirs,
so install.sh detects snap browsers and omits the flag, letting
chromium use its default profile at `~/snap/chromium/common/chromium/`.
That dir persists across restarts and snap refreshes. `BROWSER_CMD`
env var lets you override entirely.

## xpra.org apt repository

Ubuntu 24.04's packaged xpra is v3.1.5 (2020) which lacks the HTML5
client and many performance features. install.sh adds xpra.org's
official apt repo:
- GPG key: `/usr/share/keyrings/xpra.asc`
- Source: `/etc/apt/sources.list.d/xpra.sources` (DEB822 format)
- Packages: `xpra`, `xserver-xorg-video-dummy`, `matchbox-window-manager`

The install also:
- Disables xpra's built-in socket activation (`xpra-server.socket`)
  which conflicts with our custom unit
- Sets `allowed_users=anybody` in `/etc/X11/Xwrapper.config` (required
  for non-console users to run Xorg with the dummy driver)
- Creates `/etc/udev/rules.d/99-uinput.rules` for uinput access

## Files

- `browser/install.sh` — one-command deploy (adds repo, installs
  packages, renders templates, enables service)
- `browser/uninstall.sh` — clean removal (also handles legacy VNC units)
- `browser/systemd/claude-browser-xpra.service` — unit template
  (`@APP_USER@`, `@DISPLAY_NUM@`, `@XPRA_PORT@`, `@LOOP_SCRIPT@`, etc.)
- `browser/nginx/browser.conf` — location snippet template with
  sub_filter patches (`@XPRA_PORT@`)
- `browser/browser-loop.sh` — chromium restart wrapper template
  (`@BROWSER_CMD@`), deployed to `/usr/local/lib/claude-browser/`

## Operations

```bash
systemctl status claude-browser-xpra
sudo systemctl restart claude-browser-xpra        # restart full session
xpra info :99                                      # session info
journalctl -u claude-browser-xpra -f               # logs
DISPLAY=:99 xrandr                                 # check display modes
DISPLAY=:99 xwininfo -root -children               # list X windows
ss -tlnp | grep :14500                             # confirm loopback listen
```

## Multi-client behavior

With `--sharing=yes`, multiple HTML5 clients can connect simultaneously —
they all see the same display. Clicking and typing from any client moves
the same cursor. No isolation between viewers. (Without `--sharing`, xpra
is single-client and each new connection evicts the previous one — see the
flags section above.)

## Caveats

- **Audio** — disabled (`--pulseaudio=no --speaker=off --microphone=off`).
- **Clipboard** — works natively via xpra on HTTPS (Clipboard API).
  On plain HTTP, clipboard write works but read may be restricted by
  browser security; xpra provides a fallback clipboard panel.
- **Network exit** — every page load originates from myhost's network.
- **xpra updates** — the `sub_filter` scroll/mouse patches target the
  current xpra HTML5 client JS API. If xpra updates change the
  `XpraClient.prototype.getMouse` or `on_mousescroll` signatures, the
  patches may need updating.
- **Xorg wrapper** — `allowed_users=anybody` in Xwrapper.config allows
  any user to start Xorg. This is safe since only the dummy driver is
  used (no real hardware access), but be aware if other X server
  configurations exist on the host.
