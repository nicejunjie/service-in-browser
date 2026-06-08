# landing

Unified desktop UI and supporting static pages. Deployed via `./install.sh` (no sudo).

## Files

- `desktop.html` — main desktop UI at `/` (Start menu, iframe viewport, status bar, server-side state via `/api/desktop`)
- `index.html` — old service listing page, preserved at `/landing.html` (Home Service app)
- `notes.html` — scratchpad at `/notes.html` (Notes app)
- `monitor.html` — live system dashboard at `/monitor.html` (Monitor app; CPU/MEM/GPU charts, htop-style load average, process list)
- `upload.html` — quick-sync drop zone at `/upload.html` (Upload app; per-file progress, In-folder listing with Clear-all + Open-in-Files deep link, sequential XHR uploads to `/api/upload`)
- `filebrowser-patches.js` — UI enhancements injected into FileBrowser via nginx `sub_filter` (permanent toolbar buttons, mobile flex-wrap for the header, hides `#file-selection` and `.context-menu` popups)
- `install.sh` — copies files to `~/claude-web-www/`

## Updating

1. Edit the source file(s) here.
2. Run `./install.sh` (without sudo — sudo resolves `$HOME` to `/root/`).
3. Reload the browser. No nginx reload needed — served as static files.

Full architecture: [`../CLAUDE.md`](../CLAUDE.md).
