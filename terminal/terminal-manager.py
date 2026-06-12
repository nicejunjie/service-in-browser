#!/usr/bin/env python3
"""Terminal manager & system status API.

Listens on 127.0.0.1:7680, proxied by nginx at /api/.
Runs as root so it can manage systemd units.

Endpoints:
  POST /api/terminals/{n}/start   — start session + ttyd for instance N
  POST /api/terminals/{n}/stop    — stop ttyd + session for instance N
  GET  /api/terminals/status      — {"running": [1, 3, 5, ...]}
  GET  /api/system/status         — CPU, memory, uptime, terminal count
"""

import http.server
import json
import os
import pwd
import re
import shutil
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

MAX_INSTANCE = 50


def _app_user():
    """The non-root user that owns this install.

    The manager runs as root, so it can't rely on ~ or $HOME. Resolve the
    target user from $APP_USER, else from the owner of this script file.
    """
    env = os.environ.get("APP_USER") or os.environ.get("BROWSER_USER")
    if env:
        return env
    return pwd.getpwuid(os.stat(__file__).st_uid).pw_name


APP_USER = _app_user()
NOTES_FILE = os.path.expanduser(f"~{APP_USER}/.local/share/desktop-notes.md")
DESKTOP_STATE_FILE = os.path.expanduser(f"~{APP_USER}/.local/share/desktop-state.json")
# Per-host update log (real history of THIS deployment's self-updates, seeded
# with a "deployed" baseline on first run) — not the git changelog.
UPDATE_HISTORY_FILE = os.path.expanduser(f"~{APP_USER}/.local/share/vibetop-update-history.json")
UPDATE_HISTORY_MAX = 200
UPLOAD_DIR = os.environ.get(
    "UPLOAD_DIR", os.path.expanduser(f"~{APP_USER}/Uploads")
)
# Host-local service definitions (gitignored). Each entry may carry a "key" and a
# "health" URL; those are added to /api/health so the Home Service page can show
# live dots without baking personal hostnames into the repo.
SERVICES_FILE = os.path.expanduser(f"~{APP_USER}/claude-web-www/services.json")

# The git checkout this manager runs from: <repo>/terminal/terminal-manager.py.
# The Update app pulls + redeploys from here.
REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Per-process CPU snapshot for delta-based calculation
_prev_proc_snap = {}  # pid -> (utime+stime, timestamp)
_prev_proc_time = 0.0

# Whole-system CPU snapshot for delta-based calculation
# ({name: ticks}, monotonic timestamp) from the previous status call
_prev_cpu_snap = None


# ---- /api/upload helpers ---------------------------------------------------

def _read_loadavg():
    """Return [1min, 5min, 15min] load averages from /proc/loadavg, or
    [None, None, None] if it can't be read."""
    try:
        with open("/proc/loadavg") as f:
            parts = f.read().split()
        return [float(parts[0]), float(parts[1]), float(parts[2])]
    except (OSError, IndexError, ValueError):
        return [None, None, None]


def _read_amdgpu_pm_info(card_n):
    """Best-effort parse of /sys/kernel/debug/dri/N/amdgpu_pm_info — used as
    a fallback when sysfs gpu_busy_percent / hwmon temp read EBUSY under
    heavy compute. Returns {"load": int|None, "temp": int|None,
    "power_w": int|None}. Requires root (debugfs is 0700)."""
    out = {"load": None, "temp": None, "power_w": None}
    if card_n is None:
        return out
    paths = [f"/sys/kernel/debug/dri/{card_n}/amdgpu_pm_info"]
    # Some kernels expose the file under a PCI-address-based dri index that
    # doesn't match the cardN number. Probe a couple of indices defensively.
    for i in range(4):
        p = f"/sys/kernel/debug/dri/{i}/amdgpu_pm_info"
        if p not in paths:
            paths.append(p)
    for path in paths:
        try:
            with open(path) as f:
                data = f.read()
        except (FileNotFoundError, PermissionError, OSError):
            continue
        m = re.search(r"GPU Load:\s*(\d+)\s*%", data)
        if m and out["load"] is None:
            out["load"] = int(m.group(1))
        m = re.search(r"GPU Temperature:\s*(\d+)\s*C", data)
        if m and out["temp"] is None:
            out["temp"] = int(m.group(1))
        m = re.search(r"([\d.]+)\s*W\s*\(average\s+(?:SoC|GPU)\)", data)
        if m and out["power_w"] is None:
            try:
                out["power_w"] = round(float(m.group(1)))
            except ValueError:
                pass
        if out["load"] is not None and out["temp"] is not None:
            break
    return out


def _read_nvidia_gpu():
    """Best-effort NVIDIA GPU stats via nvidia-smi, used when no AMD card is
    found (portability for NVIDIA hosts). Returns a dict with the same keys the
    AMD path fills — percent/temp/vram_used_gb/vram_total_gb/power_w — or {}."""
    smi = shutil.which("nvidia-smi")
    if not smi:
        return {}
    try:
        p = subprocess.run(
            [smi, "--query-gpu=utilization.gpu,temperature.gpu,memory.used,"
                  "memory.total,power.draw",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=2)
    except Exception:
        return {}
    rows = (p.stdout or "").strip().splitlines()
    if not rows:
        return {}
    parts = [x.strip() for x in rows[0].split(",")]   # first GPU
    if len(parts) < 5:
        return {}

    def num(x):
        try:
            return float(x)
        except (ValueError, TypeError):
            return None
    util, temp, mu, mt, pw = (num(parts[0]), num(parts[1]), num(parts[2]),
                              num(parts[3]), num(parts[4]))
    out = {}
    if util is not None:
        out["percent"] = int(util)
    if temp is not None:
        out["temp"] = int(temp)
    if mu is not None:
        out["vram_used_gb"] = round(mu / 1024, 1)    # nvidia-smi reports MiB
    if mt is not None:
        out["vram_total_gb"] = round(mt / 1024, 1)
    if pw is not None:
        out["power_w"] = round(pw)
    return out


def _root_disk():
    """Block device backing '/', partition suffix stripped (nvme1n1p3 -> nvme1n1,
    sda2 -> sda), for matching /proc/diskstats. None if it can't be determined."""
    try:
        with open("/proc/mounts") as f:
            for line in f:
                p = line.split()
                if len(p) >= 2 and p[1] == "/" and p[0].startswith("/dev/"):
                    name = os.path.basename(p[0])
                    m = re.match(r"(nvme\d+n\d+|mmcblk\d+)p\d+$", name)
                    if m:
                        return m.group(1)
                    m = re.match(r"([svh]d[a-z]+)\d+$", name)
                    if m:
                        return m.group(1)
                    return name
    except Exception:
        pass
    return None


class _MultipartError(Exception):
    pass


def _chown_app(path):
    """Set ownership of `path` to APP_USER if running as root (the manager
    typically does). Best-effort — silently ignored on failure."""
    try:
        if os.geteuid() != 0:
            return
        pw = pwd.getpwnam(APP_USER)
        os.chown(path, pw.pw_uid, pw.pw_gid)
    except Exception:
        pass


def _git(args, timeout=60):
    """Run git in REPO_DIR as APP_USER (the repo owner — root trips git's
    dubious-ownership guard, and only APP_USER holds the credentials). Module
    level so both the request handler and startup seeding can use it."""
    cmd = ["sudo", "-n", "-u", APP_USER, "-H", "git", "-C", REPO_DIR] + list(args)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode == 0, (p.stdout + p.stderr).strip()
    except Exception as e:
        return False, str(e)


def _read_update_history():
    try:
        with open(UPDATE_HISTORY_FILE) as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def _write_update_history(entries):
    try:
        os.makedirs(os.path.dirname(UPDATE_HISTORY_FILE), exist_ok=True)
        with open(UPDATE_HISTORY_FILE, "w") as f:
            json.dump(entries[-UPDATE_HISTORY_MAX:], f)
        _chown_app(UPDATE_HISTORY_FILE)
    except Exception:
        pass


def _append_update_history(entry):
    h = _read_update_history()
    h.append(entry)
    _write_update_history(h)


def _seed_update_history():
    """Write a 'deployed' baseline the first time the manager runs (≈ deploy
    time), so the per-host log starts from when this deployment came up."""
    if os.path.exists(UPDATE_HISTORY_FILE):
        return
    ok, head = _git(["log", "-1", "--format=%h\t%s"])
    commit, subject = (head.split("\t", 1) + [""])[:2] if (ok and "\t" in head) else ("", "")
    _write_update_history([{"time": int(time.time()), "event": "deployed",
                            "to": commit, "subject": subject}])


def _safe_upload_name(name):
    # Browsers may send "C:\\fakepath\\foo.jpg" or "../etc/passwd".
    # Strip any directory components and disallowed characters.
    name = (name or "").replace("\\", "/").split("/")[-1].strip()
    name = re.sub(r"[\x00-\x1f]", "", name)
    if not name or name in (".", ".."):
        name = "upload"
    return name[:255]


def _unique_path(path):
    if not os.path.exists(path):
        return path
    base, ext = os.path.splitext(path)
    for i in range(1, 10000):
        cand = f"{base}-{i}{ext}"
        if not os.path.exists(cand):
            return cand
    raise _MultipartError("destination exists, too many collisions")


class _BoundaryReader:
    """Streams the body of one multipart part, stopping at the next boundary.
    Reads chunks from `src` while always holding back enough bytes to detect
    the boundary mid-chunk. On exhaustion, `done` becomes True and `next_term`
    tells the outer loop whether more parts follow (\\r\\n) or this was the
    closing boundary (--)."""
    def __init__(self, src, boundary):
        self._src = src
        self._sep = b"\r\n" + boundary
        self._buf = b""
        self.done = False
        self.next_term = b""
        self.leftover = b""   # bytes past the boundary; belong to next part

    def read(self, _size=-1):
        # Invariant: only return b"" when self.done is True (so callers like
        # shutil.copyfileobj loop until the part is fully drained).
        while not self.done:
            idx = self._buf.find(self._sep)
            if idx != -1:
                out = self._buf[:idx]
                tail = idx + len(self._sep)
                while len(self._buf) < tail + 2:
                    more = self._src.read(2)
                    if not more:
                        raise _MultipartError("unexpected EOF after boundary")
                    self._buf += more
                self.next_term = self._buf[tail:tail + 2]
                self.leftover = self._buf[tail + 2:]
                self._buf = b""
                self.done = True
                return out
            keep = len(self._sep)
            if len(self._buf) > keep:
                out = self._buf[:-keep]
                self._buf = self._buf[-keep:]
                return out
            chunk = self._src.read(65536)
            if not chunk:
                raise _MultipartError("unexpected EOF in part body")
            self._buf += chunk
        return b""


def _iter_multipart_files(src, boundary):
    """Yield (filename, file-like) for each file part in the multipart body."""
    # Discard prelude up to first boundary.
    buf = b""
    while True:
        chunk = src.read(65536)
        if not chunk:
            raise _MultipartError("empty body")
        buf += chunk
        idx = buf.find(boundary)
        if idx != -1:
            # Need 2 bytes after to know if it's the only/last boundary.
            while len(buf) < idx + len(boundary) + 2:
                more = src.read(2)
                if not more:
                    raise _MultipartError("truncated boundary")
                buf += more
            term = buf[idx + len(boundary):idx + len(boundary) + 2]
            if term == b"--":
                return  # empty form
            # Push remaining bytes back into a tiny in-memory stream so the
            # part header parser sees them along with the next read().
            leftover = buf[idx + len(boundary) + 2:]
            src = _PrependedReader(leftover, src)
            break

    while True:
        # Read headers up to blank line.
        headers = b""
        while b"\r\n\r\n" not in headers:
            chunk = src.read(4096)
            if not chunk:
                raise _MultipartError("truncated headers")
            headers += chunk
        head, _, rest = headers.partition(b"\r\n\r\n")
        src = _PrependedReader(rest, src)
        disposition = ""
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-disposition:"):
                disposition = line.decode("utf-8", "replace")
                break
        reader = _BoundaryReader(src, boundary)
        fn_match = re.search(r'filename="([^"]*)"', disposition)
        if fn_match:
            yield fn_match.group(1), reader
        # Drain anything the consumer didn't read (and drain non-file fields).
        while not reader.done:
            if not reader.read():
                break
        if reader.next_term == b"--":
            return
        # Carry over any bytes the reader buffered past the boundary so the
        # next part's headers see a contiguous stream.
        src = _PrependedReader(reader.leftover, src)


class _PrependedReader:
    """Wrap a stream so its first reads yield `head` before falling through."""
    def __init__(self, head, src):
        self._head = head
        self._src = src

    def read(self, size=-1):
        if self._head:
            if size < 0 or size >= len(self._head):
                out = self._head
                self._head = b""
                return out
            out = self._head[:size]
            self._head = self._head[size:]
            return out
        return self._src.read(size if size > 0 else 65536)


class _LimitedReader:
    """Cap reads from a socket-like stream at exactly Content-Length bytes.
    Without this, reads past the body length block forever on a keep-alive
    socket — there is no EOF signal until the client closes."""
    def __init__(self, src, length):
        self._src = src
        self._left = length

    def read(self, size=-1):
        if self._left <= 0:
            return b""
        if size is None or size < 0 or size > self._left:
            size = self._left
        data = self._src.read(size)
        self._left -= len(data)
        return data

# RAPL energy snapshot for CPU power calculation
_prev_rapl_uj = 0
_prev_rapl_time = 0.0

# Disk I/O snapshot for rate calculation
_prev_disk_sectors = (0, 0)
_prev_disk_time = 0.0


class Handler(http.server.BaseHTTPRequestHandler):
    def _get_running_terminals(self):
        out = subprocess.run(
            ["systemctl", "list-units", "claude-web-ttyd@*",
             "--no-pager", "--plain", "--no-legend"],
            capture_output=True, text=True,
        )
        running = []
        for line in out.stdout.strip().split("\n"):
            m = re.search(r"claude-web-ttyd@(\d+)", line)
            if m and "running" in line:
                running.append(int(m.group(1)))
        return sorted(running)

    def _get_system_status(self):
        # CPU: delta against the snapshot from the previous status call
        # (clients poll every few seconds, so the window is meaningful).
        # Only the very first call — or one arriving <0.5s after another —
        # falls back to a synchronous 0.1s two-read sample.
        def read_proc_stat():
            cores = {}
            with open("/proc/stat") as f:
                for line in f:
                    if line.startswith("cpu"):
                        parts = line.split()
                        name = parts[0]
                        vals = list(map(int, parts[1:]))
                        cores[name] = vals
            return cores
        global _prev_cpu_snap
        snap2 = read_proc_stat()
        prev = _prev_cpu_snap
        if prev and time.monotonic() - prev[1] >= 0.5:
            snap1 = prev[0]
        else:
            snap1 = snap2
            time.sleep(0.1)
            snap2 = read_proc_stat()
        _prev_cpu_snap = (snap2, time.monotonic())
        def calc_pct(a, b):
            idle_d = b[3] - a[3]
            total_d = sum(b) - sum(a)
            return round(100.0 * (1.0 - idle_d / max(1, total_d)), 1)
        cpu = calc_pct(snap1["cpu"], snap2["cpu"])
        cpu_cores = []
        i = 0
        while f"cpu{i}" in snap1:
            cpu_cores.append(calc_pct(snap1[f"cpu{i}"], snap2[f"cpu{i}"]))
            i += 1

        # Memory
        mem = {}
        with open("/proc/meminfo") as f:
            for line in f:
                parts = line.split()
                if parts[0] in ("MemTotal:", "MemAvailable:"):
                    mem[parts[0]] = int(parts[1])
        total_gb = mem.get("MemTotal:", 0) / 1048576
        avail_gb = mem.get("MemAvailable:", 0) / 1048576
        used_gb = total_gb - avail_gb

        # Uptime
        with open("/proc/uptime") as f:
            secs = int(float(f.read().split()[0]))
        days, rem = divmod(secs, 86400)
        hours = rem // 3600
        uptime = f"{days}d {hours}h" if days else f"{hours}h {rem % 3600 // 60}m"

        # GPU (AMD via sysfs — find discrete card by largest VRAM)
        gpu_percent = None
        gpu_vram_used_gb = None
        gpu_vram_total_gb = None
        best_card_n = None    # remember card index for the debugfs fallback
        try:
            best_card = None
            best_vram = 0
            for entry in os.listdir("/sys/class/drm"):
                m = re.match(r"card(\d+)$", entry)
                if not m:
                    continue
                dev = f"/sys/class/drm/{entry}/device"
                vram_path = f"{dev}/mem_info_vram_total"
                if not os.path.exists(vram_path):
                    continue
                try:
                    with open(vram_path) as f:
                        vram = int(f.read().strip())
                    if vram > best_vram:
                        best_vram = vram
                        best_card = dev
                        best_card_n = int(m.group(1))
                except Exception:
                    continue
            if best_card:
                gpu_vram_total_gb = round(best_vram / (1024**3), 1)
                try:
                    with open(f"{best_card}/mem_info_vram_used") as f:
                        gpu_vram_used_gb = round(int(f.read().strip()) / (1024**3), 1)
                except Exception:
                    pass
                try:
                    with open(f"{best_card}/gpu_busy_percent") as f:
                        gpu_percent = int(f.read().strip())
                except Exception:
                    pass
        except Exception:
            pass

        # Fallback: under heavy compute the amdgpu driver locks sysfs files
        # (EBUSY), so gpu_busy_percent and the hwmon temp both vanish. The
        # debugfs `amdgpu_pm_info` file is published from a different path
        # and stays readable. We use it as a backup for both util and temp.
        # Requires root (manager already runs as root) and debugfs mounted.
        pm_info = _read_amdgpu_pm_info(best_card_n)
        if gpu_percent is None and pm_info.get("load") is not None:
            gpu_percent = pm_info["load"]

        # CPU temperature (k10temp Tctl)
        cpu_temp = None
        try:
            for hwmon in os.listdir("/sys/class/hwmon"):
                p = f"/sys/class/hwmon/{hwmon}"
                with open(f"{p}/name") as f:
                    if f.read().strip() == "k10temp":
                        with open(f"{p}/temp1_input") as f2:
                            cpu_temp = round(int(f2.read().strip()) / 1000)
                        break
        except Exception:
            pass

        # GPU temperature and power (amdgpu — discrete card only, skip integrated)
        gpu_temp = None
        gpu_power_w = None
        try:
            for hwmon in sorted(os.listdir("/sys/class/hwmon")):
                p = f"/sys/class/hwmon/{hwmon}"
                with open(f"{p}/name") as f:
                    if f.read().strip() != "amdgpu":
                        continue
                label_path = f"{p}/temp1_label"
                if os.path.exists(label_path):
                    with open(label_path) as f:
                        if f.read().strip() == "edge":
                            try:
                                with open(f"{p}/temp1_input") as f2:
                                    gpu_temp = round(int(f2.read().strip()) / 1000)
                            except Exception:
                                pass
                            for pwr in ("power1_average", "power1_input"):
                                pwr_path = f"{p}/{pwr}"
                                if os.path.exists(pwr_path):
                                    try:
                                        with open(pwr_path) as f2:
                                            gpu_power_w = round(int(f2.read().strip()) / 1000000)
                                    except Exception:
                                        pass
                                    break
                            break
        except Exception:
            pass

        # Apply the debugfs fallback for temp/power too.
        if gpu_temp is None and pm_info.get("temp") is not None:
            gpu_temp = pm_info["temp"]
        if gpu_power_w is None and pm_info.get("power_w") is not None:
            gpu_power_w = pm_info["power_w"]

        # NVIDIA portability: if no AMD card was found, fill the same GPU fields
        # from nvidia-smi (no-op on AMD hosts, where the card was found above).
        if gpu_vram_total_gb is None and gpu_percent is None:
            nv = _read_nvidia_gpu()
            if gpu_percent is None:       gpu_percent = nv.get("percent")
            if gpu_temp is None:          gpu_temp = nv.get("temp")
            if gpu_vram_used_gb is None:  gpu_vram_used_gb = nv.get("vram_used_gb")
            if gpu_vram_total_gb is None: gpu_vram_total_gb = nv.get("vram_total_gb")
            if gpu_power_w is None:        gpu_power_w = nv.get("power_w")

        # CPU package power (RAPL — delta between calls)
        cpu_power_w = None
        try:
            global _prev_rapl_uj, _prev_rapl_time
            
            with open("/sys/class/powercap/intel-rapl:0/energy_uj") as f:
                uj = int(f.read().strip())
            now = time.monotonic()
            if _prev_rapl_time > 0:
                dt = now - _prev_rapl_time
                if dt > 0:
                    duj = uj - _prev_rapl_uj
                    if duj < 0:
                        with open("/sys/class/powercap/intel-rapl:0/max_energy_range_uj") as f:
                            duj += int(f.read().strip())
                    cpu_power_w = round(duj / (dt * 1000000))
            _prev_rapl_uj = uj
            _prev_rapl_time = now
        except Exception:
            pass

        # Network: read bytes from /proc/net/dev for physical interfaces
        net = {}
        try:
            with open("/proc/net/dev") as f:
                for line in f:
                    parts = line.split()
                    if not parts or not parts[0].endswith(":"):
                        continue
                    iface = parts[0].rstrip(":")
                    if iface.startswith(("enp", "eth", "wl")):
                        net[iface] = {"rx_bytes": int(parts[1]), "tx_bytes": int(parts[9])}
        except Exception:
            pass

        # Disk usage and I/O
        disk_used_gb = None
        disk_total_gb = None
        disk_read_bytes = None
        disk_write_bytes = None
        try:
            st = os.statvfs("/")
            disk_total_gb = round(st.f_frsize * st.f_blocks / (1024**3), 1)
            disk_used_gb = round(st.f_frsize * (st.f_blocks - st.f_bfree) / (1024**3), 1)
        except Exception:
            pass
        try:
            global _prev_disk_sectors, _prev_disk_time
            root_disk = _root_disk()
            with open("/proc/diskstats") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 14 and root_disk and parts[2] == root_disk:
                        rd_sectors = int(parts[5])
                        wr_sectors = int(parts[9])
                        now = time.monotonic()
                        if _prev_disk_time > 0:
                            dt = now - _prev_disk_time
                            if dt > 0:
                                disk_read_bytes = int((rd_sectors - _prev_disk_sectors[0]) * 512 / dt)
                                disk_write_bytes = int((wr_sectors - _prev_disk_sectors[1]) * 512 / dt)
                        _prev_disk_sectors = (rd_sectors, wr_sectors)
                        _prev_disk_time = now
                        break
        except Exception:
            pass

        # Top processes by CPU (delta-based like htop)
        global _prev_proc_snap, _prev_proc_time
        processes = []
        try:
            page_size = os.sysconf("SC_PAGE_SIZE")
            clk_tck = os.sysconf("SC_CLK_TCK")
            now = time.monotonic()
            dt = now - _prev_proc_time if _prev_proc_time else 0
            cur_snap = {}
            for pid_s in os.listdir("/proc"):
                if not pid_s.isdigit():
                    continue
                try:
                    with open(f"/proc/{pid_s}/stat") as f:
                        stat = f.read()
                    comm_start = stat.index("(")
                    comm_end = stat.rindex(")")
                    short_name = stat[comm_start+1:comm_end]
                    fields = stat[comm_end+2:].split()
                    utime = int(fields[11])
                    stime = int(fields[12])
                    rss = int(fields[21]) * page_size / (1024 * 1024)
                    ticks = utime + stime
                    pid = int(pid_s)
                    # Get descriptive name from cmdline
                    try:
                        with open(f"/proc/{pid_s}/cmdline") as f:
                            cmdline = f.read().split("\x00")
                        cmdline = [c for c in cmdline if c]
                        if len(cmdline) > 1 and cmdline[0].endswith(("python3", "python", "node")):
                            name = os.path.basename(cmdline[1])
                        elif cmdline:
                            name = os.path.basename(cmdline[0])
                        else:
                            name = short_name
                    except Exception:
                        name = short_name
                    cur_snap[pid] = ticks
                    cpu_pct = 0.0
                    if dt > 0 and pid in _prev_proc_snap:
                        delta_ticks = ticks - _prev_proc_snap[pid]
                        cpu_pct = (delta_ticks / clk_tck) / dt * 100
                    with open(f"/proc/{pid_s}/status") as f:
                        uid_line = [l for l in f if l.startswith("Uid:")]
                    uid = int(uid_line[0].split()[1]) if uid_line else 0
                    try:
                        user = pwd.getpwuid(uid).pw_name
                    except KeyError:
                        user = str(uid)
                    processes.append({
                        "pid": pid,
                        "name": name,
                        "cpu": round(cpu_pct, 1),
                        "mem_mb": round(rss, 1),
                        "user": user,
                    })
                except Exception:
                    continue
            _prev_proc_snap = cur_snap
            _prev_proc_time = now
            processes.sort(key=lambda p: p["cpu"], reverse=True)
            processes = processes[:30]
        except Exception:
            pass

        # IPs — show all interfaces with an assigned IP (skip lo, docker, veth)
        ips = {}
        try:
            out = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True, text=True)
            for line in out.stdout.splitlines():
                parts = line.split()
                iface = parts[1]
                if iface == "lo" or iface.startswith(("br-", "veth", "docker")):
                    continue
                ip = parts[3].split("/")[0]
                if iface not in ips:
                    ips[iface] = ip
        except Exception:
            pass

        running = self._get_running_terminals()
        result = {
            "hostname": socket.gethostname(),
            "ips": ips,
            "cpu_percent": round(cpu, 1),
            "cpu_cores": cpu_cores,
            # Load averages from /proc/loadavg (1-, 5-, 15-minute). The full
            # triple is shown in the Monitor app; the taskbar shows just the
            # 1-min value as a representative single number.
            "load_avg": _read_loadavg(),
            "memory_used_gb": round(used_gb, 1),
            "memory_total_gb": round(total_gb, 1),
            "uptime": uptime,
            "terminals_running": len(running),
            "network": net,
            "processes": processes,
        }
        if gpu_percent is not None:
            result["gpu_percent"] = gpu_percent
        if gpu_vram_used_gb is not None:
            result["gpu_vram_used_gb"] = gpu_vram_used_gb
        if gpu_vram_total_gb is not None:
            result["gpu_vram_total_gb"] = gpu_vram_total_gb
        if cpu_temp is not None:
            result["cpu_temp"] = cpu_temp
        if gpu_temp is not None:
            result["gpu_temp"] = gpu_temp
        if cpu_power_w is not None:
            result["cpu_power_w"] = cpu_power_w
        if gpu_power_w is not None:
            result["gpu_power_w"] = gpu_power_w
        if disk_total_gb is not None:
            result["disk_total_gb"] = disk_total_gb
            result["disk_used_gb"] = disk_used_gb
        if disk_read_bytes is not None:
            result["disk_read_bytes"] = disk_read_bytes
            result["disk_write_bytes"] = disk_write_bytes
        return result

    def do_POST(self):
        m = re.match(r"/api/terminals/(\d+)/(start|stop)$", self.path)
        if m:
            return self._handle_terminal(m)
        if self.path == "/api/browser/open":
            return self._handle_browser_open()
        if self.path == "/api/notes":
            return self._handle_notes_save()
        if self.path == "/api/desktop":
            return self._handle_desktop_save()
        if self.path == "/api/upload":
            return self._handle_upload()
        if self.path == "/api/upload/clear":
            return self._handle_upload_clear()
        if self.path == "/api/update/check":
            return self._handle_update_check()
        if self.path == "/api/update":
            return self._handle_update()
        if self.path == "/api/update/history/clear":
            _write_update_history([])
            return self._json(200, {"ok": True})
        self.send_error(404)

    def _handle_upload_clear(self):
        # Delete every regular file directly inside UPLOAD_DIR. Subdirectories
        # are left alone (this endpoint is for clearing the quick-sync inbox,
        # not nuking arbitrary trees).
        if not os.path.isdir(UPLOAD_DIR):
            self._json(200, {"ok": True, "removed": 0})
            return
        removed = 0
        for name in os.listdir(UPLOAD_DIR):
            p = os.path.join(UPLOAD_DIR, name)
            try:
                if os.path.isfile(p) and not os.path.islink(p):
                    os.remove(p)
                    removed += 1
            except OSError:
                pass
        self._json(200, {"ok": True, "removed": removed})

    def _handle_notes_save(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > 1048576:
            self._json(400, {"error": "too large (1MB max)"})
            return
        body = self.rfile.read(length) if length else b""
        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid json"})
            return
        content = data.get("content", "")
        os.makedirs(os.path.dirname(NOTES_FILE), exist_ok=True)
        with open(NOTES_FILE, "w") as f:
            f.write(content)
        self._json(200, {"ok": True})

    def _handle_upload(self):
        # Parse multipart/form-data and stream each "file" part directly into
        # UPLOAD_DIR. We don't use cgi.FieldStorage because it spools entire
        # uploads to memory/temp first; this hand-parser streams chunk-by-chunk
        # so multi-GB uploads stay flat in memory.
        ctype = self.headers.get("Content-Type", "")
        m = re.match(r'multipart/form-data;\s*boundary=(?:"([^"]+)"|([^;\s]+))', ctype)
        if not m:
            self._json(400, {"error": "expected multipart/form-data"})
            return
        boundary = ("--" + (m.group(1) or m.group(2))).encode()
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._json(411, {"error": "Content-Length required"})
            return
        if length <= 0:
            self._json(411, {"error": "Content-Length required"})
            return
        body = _LimitedReader(self.rfile, length)
        os.makedirs(UPLOAD_DIR, exist_ok=True)
        _chown_app(UPLOAD_DIR)
        saved, total_bytes = [], 0
        try:
            for filename, src in _iter_multipart_files(body, boundary):
                safe = _safe_upload_name(filename)
                dst = _unique_path(os.path.join(UPLOAD_DIR, safe))
                with open(dst, "wb") as out:
                    shutil.copyfileobj(src, out)
                _chown_app(dst)
                size = os.path.getsize(dst)
                total_bytes += size
                saved.append({"name": os.path.basename(dst), "size": size})
        except _MultipartError as e:
            self._json(400, {"error": str(e)})
            return
        self._json(200, {"ok": True, "saved": saved, "bytes": total_bytes,
                         "dir": UPLOAD_DIR})

    def _handle_desktop_save(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > 4096:
            self._json(400, {"error": "too large"})
            return
        body = self.rfile.read(length) if length else b""
        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid json"})
            return
        # Whitelist: only persist {open: [str], active: str|null}. open is
        # capped at 16 entries to keep the file tiny; ids are stored verbatim
        # (the client whitelists against its own APPS map on read).
        open_apps = data.get("open", []) or []
        if not isinstance(open_apps, list):
            self._json(400, {"error": "open must be a list"})
            return
        open_apps = [str(x) for x in open_apps[:16]]
        active = data.get("active")
        if active is not None and not isinstance(active, str):
            self._json(400, {"error": "active must be a string or null"})
            return
        state = {"open": open_apps, "active": active}
        os.makedirs(os.path.dirname(DESKTOP_STATE_FILE), exist_ok=True)
        with open(DESKTOP_STATE_FILE, "w") as f:
            json.dump(state, f)
        self._json(200, {"ok": True})

    def _handle_browser_open(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > 4096:
            self._json(400, {"error": "payload too large"})
            return
        body = self.rfile.read(length) if length else b""
        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid json"})
            return
        url = data.get("url", "")
        if not url or not url.startswith(("http://", "https://")):
            self._json(400, {"error": "invalid url"})
            return
        if any(c in url for c in ('"', "'", ";", "`", "$", "(", ")", "\n")):
            self._json(400, {"error": "invalid characters in url"})
            return
        user = os.environ.get("BROWSER_USER", APP_USER)
        try:
            uid = pwd.getpwnam(user).pw_uid
        except KeyError:
            self._json(500, {"error": f"unknown user: {user}"})
            return
        profile = f"/home/{user}/snap/chromium/common/xpra-profile"
        subprocess.Popen(
            ["su", "-", user, "-c",
             f'DISPLAY=:99 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus'
             f' /snap/bin/chromium --user-data-dir={profile} "{url}"'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self._json(200, {"ok": True, "url": url})

    def _handle_terminal(self, m):
        n, action = int(m.group(1)), m.group(2)
        if n < 1 or n > MAX_INSTANCE:
            self._json(400, {"error": f"instance must be 1-{MAX_INSTANCE}"})
            return
        units = [f"claude-web-session@{n}.service", f"claude-web-ttyd@{n}.service"]
        if action == "stop":
            units.reverse()
        try:
            subprocess.run(
                ["systemctl", action, "--no-block"] + units,
                check=True, capture_output=True, text=True,
            )
        except subprocess.CalledProcessError as e:
            self._json(500, {"error": e.stderr.strip()})
            return
        self._json(200, {"ok": True, "action": action, "instance": n})

    # ---- Update (git pull + redeploy) -------------------------------------
    def _git_as_user(self, args, timeout=60):
        """Run a git command in REPO_DIR as APP_USER. See module-level _git()."""
        return _git(args, timeout)

    def _update_version_info(self):
        ok, head = self._git_as_user(["log", "-1", "--format=%h\t%cd\t%s",
                                      "--date=short"])
        info = {"repo": REPO_DIR}
        if ok and "\t" in head:
            commit, date, subject = head.split("\t", 2)
            info.update({"commit": commit, "date": date, "subject": subject})
        else:
            info["error"] = head
        # Per-host update log — the REAL self-update events for this deployment
        # (newest first), seeded with a "deployed" baseline. Not the git changelog.
        _seed_update_history()
        info["history"] = list(reversed(_read_update_history()))
        return info

    def _handle_update_check(self):
        """Fetch from GitHub and report whether newer commits exist — WITHOUT
        applying anything. 'git fetch' updates the remote-tracking ref only; the
        working tree and HEAD are untouched, so this is a read-only probe."""
        ok, out = self._git_as_user(["fetch", "--quiet", "origin", "main"],
                                    timeout=120)
        if not ok:
            self._json(200, {"ok": False,
                             "message": "Couldn't reach GitHub — check the host's network.",
                             "detail": (out or "")[:300]})
            return
        _, local = self._git_as_user(["rev-parse", "HEAD"])
        _, remote = self._git_as_user(["rev-parse", "origin/main"])
        commits = []
        if local and remote and local != remote:
            cok, cout = self._git_as_user(
                ["log", "--format=%h\x1f%s", local + "..origin/main"])
            if cok and cout:
                for line in cout.splitlines():
                    p = line.split("\x1f")
                    if len(p) == 2:
                        commits.append({"commit": p[0], "subject": p[1]})
        self._json(200, {"ok": True, "behind": len(commits), "commits": commits,
                         "local": (local or "")[:7], "remote": (remote or "")[:7]})

    def _handle_update(self):
        """Pull the latest from GitHub and redeploy whatever changed. Each step's
        output is returned as a log. The manager restarts itself (out-of-band) at
        the end only if its own file changed, so the new code takes effect."""
        log = []

        def add(name, ok, out):
            log.append({"name": name, "ok": bool(ok), "output": (out or "").strip()})
            return ok

        _, before = self._git_as_user(["rev-parse", "HEAD"])
        ok, out = self._git_as_user(["pull", "--ff-only"], timeout=120)
        add("git pull", ok, out)
        if not ok:
            _append_update_history({"time": int(time.time()), "event": "failed",
                                    "message": (out or "")[:200]})
            self._json(200, {"ok": False, "log": log,
                             "message": "git pull failed — resolve it on the host"})
            return
        _, after = self._git_as_user(["rev-parse", "HEAD"])

        changed = []
        if before and after and before != after:
            cok, cout = self._git_as_user(["diff", "--name-only",
                                           before + ".." + after])
            if cok:
                changed = [l for l in cout.splitlines() if l]

        if not changed:
            self._json(200, {"ok": True, "log": log, "changed": [],
                             "message": "Already up to date."})
            return

        # Record this real update event in the per-host log (the commits pulled).
        nok, nlog = self._git_as_user(["log", "--format=%h\x1f%s", before + ".." + after])
        commits = []
        if nok and nlog:
            for line in nlog.splitlines():
                p = line.split("\x1f")
                if len(p) == 2:
                    commits.append({"commit": p[0], "subject": p[1]})
        _append_update_history({"time": int(time.time()), "event": "updated",
                                "from": (before or "")[:7], "to": (after or "")[:7],
                                "commits": commits})

        def deploy(name, argv, env_extra):
            env = dict(os.environ)
            env.update(env_extra)
            try:
                p = subprocess.run(argv, cwd=REPO_DIR, env=env,
                                   capture_output=True, text=True, timeout=300)
                add(name, p.returncode == 0, p.stdout + p.stderr)
            except Exception as e:
                add(name, False, str(e))

        touched = lambda prefix: any(c.startswith(prefix) for c in changed)
        # landing/ → static apps; run as APP_USER ($HOME must be the user's, set
        # by sudo -H). No login shell, so no MOTD banner in the output.
        if touched("landing/"):
            try:
                p = subprocess.run(
                    ["sudo", "-n", "-u", APP_USER, "-H",
                     os.path.join(REPO_DIR, "landing", "install.sh")],
                    cwd=REPO_DIR, capture_output=True, text=True, timeout=120)
                add("deploy desktop & apps", p.returncode == 0, p.stdout + p.stderr)
            except Exception as e:
                add("deploy desktop & apps", False, str(e))
        # browser/ and terminal/ touch nginx → run as root (manager is root) with
        # APP_USER passed in; skip apt/systemd, just redeploy files + reload nginx.
        base_env = {"APP_USER": APP_USER, "INSTALL_DEPS": "0", "INSTALL_SYSTEMD": "0"}
        if touched("browser/"):
            deploy("deploy browser", ["./browser/install.sh"], base_env)
        if touched("terminal/"):
            deploy("deploy terminal & nginx", ["./terminal/install.sh"], base_env)

        # Restart the manager out-of-band (via a transient timer so it survives
        # our own death) only if its code changed — after the response is sent.
        restart = "terminal/terminal-manager.py" in changed
        self._json(200, {"ok": True, "log": log, "changed": changed,
                         "restart": restart,
                         "message": ("Updated. Restarting the API to apply manager "
                                     "changes…" if restart else "Updated.")})
        if restart:
            try:
                subprocess.Popen(
                    ["systemd-run", "--on-active=3",
                     "systemctl", "restart", "claude-web-manager.service"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass

    def do_GET(self):
        if self.path == "/api/terminals/status":
            self._json(200, {"running": self._get_running_terminals()})
            return
        if self.path == "/api/update":
            self._json(200, self._update_version_info())
            return
        if self.path == "/api/system/status":
            self._json(200, self._get_system_status())
            return
        if self.path == "/api/notes":
            try:
                with open(NOTES_FILE) as f:
                    content = f.read()
            except FileNotFoundError:
                content = ""
            self._json(200, {"content": content})
            return
        if self.path == "/api/desktop":
            try:
                with open(DESKTOP_STATE_FILE) as f:
                    state = json.load(f)
            except (FileNotFoundError, json.JSONDecodeError):
                state = {"open": [], "active": None}
            self._json(200, state)
            return
        if self.path == "/api/upload/list":
            files = []
            if os.path.isdir(UPLOAD_DIR):
                for name in sorted(os.listdir(UPLOAD_DIR)):
                    p = os.path.join(UPLOAD_DIR, name)
                    try:
                        st = os.stat(p)
                    except OSError:
                        continue
                    if not os.path.isfile(p) or os.path.islink(p):
                        continue
                    files.append({"name": name, "size": st.st_size,
                                  "mtime": int(st.st_mtime)})
            # Newest first — quick-sync users care about what just landed.
            files.sort(key=lambda f: f["mtime"], reverse=True)
            # Compute path relative to APP_USER's home so the client can deep-
            # link into FileBrowser (which is rooted at ~).
            home = os.path.expanduser(f"~{APP_USER}").rstrip("/") + "/"
            rel = UPLOAD_DIR[len(home):] if UPLOAD_DIR.startswith(home) else None
            self._json(200, {"dir": UPLOAD_DIR, "rel_to_home": rel, "files": files})
            return
        if self.path == "/api/health":
            self._json(200, self._check_health())
            return
        self.send_error(404)

    def _check_health(self):
        import urllib.request, ssl
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        checks = {
            "terminals": "http://127.0.0.1:7681/t1/",
            "browser": "http://127.0.0.1:14500/",
            "files": "http://127.0.0.1:8085/files/",
        }
        # Merge host-local services (each with a "key" and a "health" URL).
        try:
            with open(SERVICES_FILE) as f:
                for s in json.load(f):
                    key, url = s.get("key"), s.get("health") or s.get("url")
                    if key and url:
                        checks[key] = url
        except Exception:
            pass
        # Probe concurrently — sequentially, one down service (2s timeout)
        # delays every dot behind it.
        def probe(name_url):
            name, url = name_url
            try:
                kw = {"timeout": 2}
                if url.startswith("https"):
                    kw["context"] = ctx
                urllib.request.urlopen(url, **kw)
                return name, True
            except urllib.error.HTTPError:
                return name, True
            except Exception:
                return name, False
        with ThreadPoolExecutor(max_workers=8) as ex:
            return dict(ex.map(probe, checks.items()))

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7680
    # Threaded: a slow request (multi-GB upload, health probe, the 0.1s CPU
    # sample fallback) must not block the status polls every desktop client
    # sends — with the plain single-threaded HTTPServer an upload froze every
    # other endpoint for its whole duration. The _prev_* snapshot globals are
    # shared across threads; a rare concurrent-poll race only skews one
    # reading, which the next poll corrects.
    # Seed the per-host update log with a "deployed" baseline on first start
    # (≈ deploy time) so the history starts from when this deployment came up.
    _seed_update_history()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    print(f"terminal-manager listening on 127.0.0.1:{port}")
    server.serve_forever()
