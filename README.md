# Vibetop

**Your self-hosted machine, as a desktop in any browser tab — even your phone.**

A unified "mini-OS" desktop experience served in the browser, exposed publicly
over HTTPS via Cloudflare Tunnel with Access auth. The root page is a desktop-like
UI launchable from a Start menu with seven everyday apps — **Home Service,
Terminal, Browser, Files, Notes, Monitor, Upload** — plus a self-updating
**Update** app. Open-app state is synced server-side so phone and computer share
the same desktop. Installable as a PWA; the Terminal even keeps iOS voice
dictation working. Deploys to any Ubuntu host with one command (AMD or NVIDIA).

## Features

- **Terminal** — persistent bash sessions over ttyd; tabs survive disconnects via a custom `claude-session` daemon (256 KB ring buffer + 50k-line xterm.js scrollback). On touch, tapping the terminal raises the keyboard via an in-page overlay that makes **iOS dictation work** (no character pile-up); on Windows, Ctrl+V pastes cleanly
- **Browser** — a real, persistent Chromium driven by xpra's HTML5 client; mobile gets tap-click, drag-scroll, two-finger pinch zoom, and a toggleable on-screen keyboard
- **Files** — FileBrowser rooted at `~`, every toolbar action visible inline (wraps to multiple rows on mobile). Word/Excel/PPT files get **View** (server renders a read-only PDF, shown in an in-app viewer) and **Edit** (opens in LibreOffice on the Browser desktop) buttons
- **Notes** — single-page Markdown scratchpad, auto-saves
- **Monitor** — live CPU/MEM/GPU charts, htop-style load average, top processes
- **Upload** — quick photo-sync drop zone; per-file progress, In-folder listing, Open-in-Files deep link
- **Update** — one-tap self-update: `git pull` from GitHub, redeploy only what changed, and an **update-history changelog** with the installed commit badged
- **Status bar** — live system stats (CPU %/°, MEM, GPU %/°, VRAM) at the bottom of every desktop. GPU from AMD sysfs (with a debugfs fallback when it locks under compute) **or NVIDIA `nvidia-smi`**

## Sub-projects

| Sub-project | URL path | What |
|---|---|---|
| `terminal` | `/t1/`..`/t50/`, `/terminals/`, `/api/` | Dynamic persistent bash terminals (ttyd + claude-session) + manager API |
| `browser`  | `/browser/` | Persistent Chromium viewable via xpra HTML5 client |
| `landing`  | `/` | Unified desktop UI with tab bar, iframe viewport, and status bar |
| `files`    | `/files/` | FileBrowser file manager rooted at `~` |
| `tunnel`   | — | Cloudflare Tunnel + Access config for public HTTPS |

## Deploy

One command does the whole stack (installs deps, runs every sub-installer in
order, health-checks), locally or to a remote host over SSH:

```bash
./deploy.sh                                # deploy on this machine
./deploy.sh --remote user@host             # rsync to host:~/vibetop and deploy there
# flags: --no-browser  --no-files  --with-tunnel  --dry-run
```

Or run the per-project installers by hand (the order `deploy.sh` uses; each is
idempotent, `--dry-run`-able, env-var configurable):

```bash
sudo ./terminal/install.sh   # nginx skeleton + manager API + ttyd
sudo ./browser/install.sh    # xpra + Chromium (snap)
sudo ./files/install.sh      # FileBrowser at /files/
./landing/install.sh         # desktop UI + static apps (no sudo)
sudo ./tunnel/install.sh     # cloudflared (tunnel setup is interactive)
```

The installers pull their own dependencies — `ttyd`/`nginx`/`acl` (apt), `xpra`
(xpra.org repo) + `chromium` (snap), and the `filebrowser` release binary — and
set up the systemd units, nginx site, and the www-data home-dir ACL. Validated
end-to-end on AMD+NVIDIA and AMD+AMD Ubuntu 24.04 hosts. Remotely-deployed hosts
are full installs — they self-update from the Start menu like the primary box.

See [`CLAUDE.md`](CLAUDE.md) for full architecture, health checks, and operational
commands, and [`docs/`](docs/) for deep dives.

## Screenshots

| Desktop — Files | Desktop — Browser |
|---|---|
| ![Files app on the desktop: FileBrowser toolbar with every action (Browser, Share, Rename, Copy, Move, Delete, Download, View, Upload, Info, Select) inline. Taskbar at the bottom shows the Start button, open apps (Terminal, Files, Browser), and live CPU/MEM/GPU/VRAM stats.](docs/images/desktop-files.jpg) | ![Browser app on the desktop: an embedded Chromium served via the xpra HTML5 client, with floating zoom controls (−/⟲/+) at lower-left and an on-screen keyboard chip at lower-right for touch use.](docs/images/desktop-browser.jpg) |

| Mobile — Start menu | Mobile — Terminal + keyboard |
|---|---|
| ![Mobile view: Terminal app showing four persistent ttyd tabs (T1–T4) with `echo "hello world"` running in T2. The Start menu is open over the app, listing Home Service, Terminal, Browser, Files, Notes, Monitor, and Upload — running apps marked with a green dot.](docs/images/mobile-startmenu.jpg) | ![Mobile view: tapping inside Terminal pops the native iOS keyboard. xterm.js fits the visible portion and the iOS text-suggestion bar sits between the terminal and the keyboard.](docs/images/mobile-keyboard.jpg) |
