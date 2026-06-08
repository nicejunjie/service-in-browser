# service-in-browser

A unified "mini-OS" desktop experience served in the browser, exposed publicly
over HTTPS via Cloudflare Tunnel with Access auth. The root page is a desktop-like
UI with five tabs: **Home, Terminal, Browser, Files, and Notes**.

## Sub-projects

| Sub-project | URL path | What |
|---|---|---|
| `terminal` | `/t1/`..`/t50/`, `/terminals/`, `/api/` | Dynamic persistent bash terminals (ttyd + claude-session) + manager API |
| `browser`  | `/browser/` | Persistent Chromium viewable via xpra HTML5 client |
| `landing`  | `/` | Unified desktop UI with tab bar, iframe viewport, and status bar |
| `files`    | `/files/` | FileBrowser file manager rooted at `~` |
| `tunnel`   | — | Cloudflare Tunnel + Access config for public HTTPS |

## Deploy

Each sub-project has an idempotent `install.sh`. Order matters on first deploy:

```bash
sudo ./terminal/install.sh   # nginx skeleton + manager API
sudo ./browser/install.sh    # nginx snippet for the browser
./landing/install.sh         # desktop UI + file manager (no sudo)
sudo ./tunnel/install.sh     # cloudflared binary (tunnel setup is interactive)
```

All scripts support `--dry-run` and are configurable via env vars (see script headers).

See [`CLAUDE.md`](CLAUDE.md) for full architecture, health checks, and operational
commands, and [`docs/`](docs/) for deep dives.

## Screenshots

| Desktop — Files | Desktop — Browser |
|---|---|
| ![Files app on the desktop: FileBrowser toolbar with every action (Browser, Share, Rename, Copy, Move, Delete, Download, View, Upload, Info, Select) inline. Taskbar at the bottom shows the Start button, open apps (Terminal, Files, Browser), and live CPU/MEM/GPU/VRAM stats.](docs/images/desktop-files.jpg) | ![Browser app on the desktop: an embedded Chromium served via the xpra HTML5 client, with floating zoom controls (−/⟲/+) at lower-left and an on-screen keyboard chip at lower-right for touch use.](docs/images/desktop-browser.jpg) |

| Mobile — Start menu | Mobile — Terminal + keyboard |
|---|---|
| ![Mobile view: Terminal app showing four persistent ttyd tabs (T1–T4) with `echo "hello world"` running in T2. The Start menu is open over the app, listing Home Service, Terminal, Browser, Files, Notes, and Monitor — running apps marked with a green dot.](docs/images/mobile-startmenu.jpg) | ![Mobile view: tapping inside Terminal pops the native iOS keyboard. xterm.js fits the visible portion and the iOS text-suggestion bar sits between the terminal and the keyboard.](docs/images/mobile-keyboard.jpg) |
