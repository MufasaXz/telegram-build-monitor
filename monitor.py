#!/usr/bin/env python3
"""AOSP build monitor -> Telegram.

Started by autohook.sh when `m` / `mka` / `ax` begins a build. It follows the
build log, keeps one Telegram message updated, then uploads the ROM (or sends
the error log if the build failed).

Settings are read from config.env next to this file. Environment variables win.
"""
import os
import re
import sys
import time
import signal
from pathlib import Path

import requests

HERE = Path(__file__).resolve().parent
CONFIG_FILE = Path(os.environ.get("CI_CONFIG") or (HERE / "config.env"))


def _load_config():
    cfg = {}
    try:
        for line in CONFIG_FILE.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            cfg[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return cfg


_CFG = _load_config()


def setting(name):
    return os.environ.get(name) or _CFG.get(name, "")


BOT_TOKEN = setting("BOT_TOKEN")
SEND_TO = (setting("SEND_TO") or "group").lower()
USER_ID = setting("USER_ID")
CHAT_ID = setting("CHAT_ID")
PIXELDRAIN_API = setting("PIXELDRAIN_API")

# "dm" sends to USER_ID, anything else sends to the group CHAT_ID.
TARGET_CHAT = USER_ID if SEND_TO == "dm" else CHAT_ID

UPDATE_INTERVAL = 43
UPLOAD_RETRIES = 3
EXTRA_UPLOAD_FILES = ["boot.img", "vendor_boot.img", "dtbo.img"]

# Wait for a real soong/ninja process before posting anything.
CONFIRM_TIMEOUT = 150
CONFIRM_STREAK = 2
POLL_INTERVAL = 3
LOG_MIN_BYTES = 1024

ROM_ALIASES = {
    "clover": "Clover",
    "axion": "AxionAOSP",
    "derp": "DerpFest",
    "derpfest": "DerpFest",
    "lineage": "LineageOS",
    "evolution": "Evolution X",
    "evox": "Evolution X",
    "crdroid": "crDroid",
    "pixelos": "PixelOS",
    "aosp": "AOSP",
    "rising": "RisingOS",
    "infinity": "Infinity",
    "superior": "Superior",
    "paranoid": "Paranoid Android",
}


# ---------------------------------------------------------------------------
# Build metadata
# ---------------------------------------------------------------------------
def _env(name, default=""):
    return os.environ.get(name, default).strip()


CI_TOP = _env("CI_TOP") or os.getcwd()
CI_PRODUCT = _env("CI_PRODUCT")
CI_VARIANT = _env("CI_VARIANT")
CI_RELEASE = _env("CI_RELEASE")
CI_TARGETS = _env("CI_TARGETS")
CI_LOG = _env("CI_LOG")
CI_RC_FILE = _env("CI_RC_FILE")
CI_DONE_FILE = _env("CI_DONE_FILE")

DEVICE = _env("CI_DEVICE") or (CI_PRODUCT.split("_")[-1] if CI_PRODUCT else "unknown")


def _android_version():
    ver = _env("CI_ANDROID_VERSION")
    if ver:
        return ver
    for manifest in (f"{CI_TOP}/.repo/manifests/default.xml",
                     f"{CI_TOP}/.repo/manifest.xml"):
        try:
            with open(manifest) as f:
                m = re.search(r"android-(\d+)", f.read())
                if m:
                    return m.group(1)
        except OSError:
            pass
    return "Unknown"


def _rom_name():
    override = _env("CI_ROM_NAME")
    if override:
        return override
    if CI_PRODUCT:
        prefix = CI_PRODUCT.split("_")[0]
        return ROM_ALIASES.get(prefix.lower(), prefix[:1].upper() + prefix[1:])
    return Path(CI_TOP).name


ANDROID_VERSION = _android_version()
ROM_NAME = _rom_name()
BUILD_TYPE = CI_VARIANT or "unknown"
OUT_DIR = _env("OUT") or f"{CI_TOP}/out/target/product/{DEVICE}"
ERROR_LOG = f"{CI_TOP}/out/error.log"


# ---------------------------------------------------------------------------
# Telegram
# ---------------------------------------------------------------------------
def tg_req(method, data=None, files=None):
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"
    try:
        if files:
            resp = requests.post(url, data=data, files=files, timeout=120)
        else:
            resp = requests.post(url, json=data, timeout=30)
        payload = resp.json()
    except Exception as e:
        print(f"Telegram {method} error: {e}")
        return {}
    if not payload.get("ok"):
        print(f"Telegram {method} failed: {payload.get('description', resp.text[:200])}")
    return payload


def send_msg(text, msg_id=None, kb=None):
    data = {"chat_id": TARGET_CHAT, "text": text, "parse_mode": "HTML"}
    if kb:
        data["reply_markup"] = kb
    if msg_id:
        data["message_id"] = msg_id
        return tg_req("editMessageText", data)
    return tg_req("sendMessage", data).get("result", {}).get("message_id")


def pin_msg(msg_id):
    tg_req("pinChatMessage", {"chat_id": TARGET_CHAT, "message_id": msg_id,
                              "disable_notification": True})


def send_doc(file_path, caption=""):
    try:
        if not os.path.exists(file_path) or os.path.getsize(file_path) == 0:
            send_msg(f"{caption}\nLog file is empty or missing.")
            return
        if os.path.getsize(file_path) > 45 * 1024 * 1024:
            url = upload_gofile(file_path)
            if url:
                send_msg(f"{caption}\nLog exceeds Telegram limit. Uploaded to: {url}")
            else:
                send_msg(f"{caption}\nLog exceeds limit and GoFile upload failed.")
            return
        with open(file_path, "rb") as f:
            tg_req("sendDocument",
                   data={"chat_id": TARGET_CHAT, "caption": caption, "parse_mode": "HTML"},
                   files={"document": f})
    except Exception as e:
        print(f"send_doc error: {e}")


# ---------------------------------------------------------------------------
# Uploads
# ---------------------------------------------------------------------------
def upload_with_retry(fn, file_path):
    for attempt in range(1, UPLOAD_RETRIES + 1):
        url = fn(file_path)
        if url:
            return url
        print(f"Upload attempt {attempt}/{UPLOAD_RETRIES} failed for {Path(file_path).name}")
        if attempt < UPLOAD_RETRIES:
            time.sleep(5)
    return None


def upload_gofile(file_path):
    print(f"Uploading {Path(file_path).name} to GoFile...")
    try:
        svr = requests.get("https://api.gofile.io/servers", timeout=30).json()["data"]["servers"][0]["name"]
        with open(file_path, "rb") as f:
            resp = requests.post(f"https://{svr}.gofile.io/uploadFile", files={"file": f}, timeout=3600).json()
        if resp["status"] == "ok":
            return resp["data"]["downloadPage"]
    except Exception:
        pass
    return None


def upload_pixeldrain(file_path):
    print(f"Uploading {Path(file_path).name} to PixelDrain...")
    try:
        with open(file_path, "rb") as f:
            resp = requests.put(
                f"https://pixeldrain.com/api/file/{Path(file_path).name}",
                data=f, auth=("", PIXELDRAIN_API), timeout=3600,
            ).json()
        if resp.get("success"):
            return f"https://pixeldrain.com/u/{resp['id']}"
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# Is a build really running?
# ---------------------------------------------------------------------------
_BUILD_PROCS = {"soong_ui.bash", "ninja", "soong_build"}


def _proc_is_build(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            argv0 = f.read().split(b"\x00")[0].decode("utf-8", "replace")
        if not argv0 or os.path.basename(argv0) not in _BUILD_PROCS:
            return False
        cwd = os.readlink(f"/proc/{pid}/cwd")
        return cwd == CI_TOP or cwd.startswith(CI_TOP + os.sep)
    except OSError:
        return False


def build_process_running():
    try:
        for pid in os.listdir("/proc"):
            if pid.isdigit() and _proc_is_build(pid):
                return True
    except OSError:
        pass
    return False


# The shell that ran `m` stays alive for the whole build and writes the done
# file afterwards. If it disappears first, the build died with it.
_LAUNCH_PPID = os.getppid()


def launcher_alive():
    if _LAUNCH_PPID <= 1:
        return True
    return os.getppid() == _LAUNCH_PPID


def _log_size():
    try:
        return os.path.getsize(CI_LOG)
    except OSError:
        return 0


def wait_for_real_build():
    deadline = time.time() + CONFIRM_TIMEOUT
    streak = 0
    while time.time() < deadline:
        if CI_DONE_FILE and os.path.exists(CI_DONE_FILE):
            return False
        if not launcher_alive():
            return False
        if build_process_running() or _log_size() > LOG_MIN_BYTES:
            streak += 1
            if streak >= CONFIRM_STREAK:
                return True
        else:
            streak = 0
        time.sleep(POLL_INTERVAL)
    return False


# ---------------------------------------------------------------------------
# Progress + message
# ---------------------------------------------------------------------------
def _tail_lines(path, n=300, chunk=262144):
    """Read only the tail: build logs can be hundreds of MB."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return []
    if size == 0:
        return []
    try:
        with open(path, "rb") as f:
            if size > chunk:
                f.seek(size - chunk)
                f.readline()
            data = f.read()
    except OSError:
        return []
    return data.decode("utf-8", "replace").splitlines()[-n:]


def fetch_progress():
    if not CI_LOG or not os.path.exists(CI_LOG):
        return 0, 0, 0
    for line in reversed(_tail_lines(CI_LOG, 300)):
        m = re.search(r"(\d+)%\s+(\d+)/(\d+)", line.replace("[", "").replace("]", ""))
        if m:
            return int(m.group(1)), int(m.group(2)), int(m.group(3))
        m = re.search(r"\[(\d+)/(\d+)\]", line)
        if m:
            curr, total = int(m.group(1)), int(m.group(2))
            pct = int(100 * curr / total) if total else 0
            return pct, curr, total
    return 0, 0, 0


def format_msg(status, pct, curr, total, start_time, rom=None, size=None,
               rate=None, eta=None):
    elapsed = int(time.time() - start_time)
    h, r = divmod(elapsed, 3600)
    m, s = divmod(r, 60)

    icons = {"started": "⚙️", "success": "✅", "failed": "❌", "stopped": "🛑"}
    heads = {"started": "Build In Progress", "success": "Build Successful",
             "failed": "Build Failed", "stopped": "Build Stopped"}

    text = f"{icons[status]} <b>{heads[status]} for {ROM_NAME} on {DEVICE}</b>\n"

    if status in ("started", "success"):
        filled = int(10 * pct / 100) if total > 0 else 0
        bar = f"[{'█' * filled}{'░' * (10 - filled)}]"
        text += f"📊 Progress: <code>{bar}</code> {pct}%\n"
        text += f"   Actions: <code>{curr}/{total}</code>\n"
        if rate is not None and rate > 0:
            text += f"   Actions/sec: <code>{rate:.2f}</code>\n"

    text += f"⏳ Elapsed: <code>{h:02d}h {m:02d}m {s:02d}s</code>\n"
    if status == "started" and eta is not None and eta > 0:
        eh, er = divmod(int(eta), 3600)
        em, es = divmod(er, 60)
        text += f"⏱️ ETA: <code>{eh:02d}h {em:02d}m {es:02d}s</code>\n"

    if status == "success" and rom:
        text += f"📦 ROM: <code>{rom}</code>\n"
        text += f"💾 Size: <code>{size:.2f} GB</code>\n"

    text += "\n🔧 Configuration:\n"
    text += f"  Variant: <code>{BUILD_TYPE}</code>\n"
    if CI_TARGETS:
        text += f"  Target: <code>{CI_TARGETS}</code>\n"
    if CI_RELEASE:
        text += f"  Release: <code>{CI_RELEASE}</code>\n"

    return text


# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------
def read_rc():
    try:
        with open(CI_RC_FILE) as f:
            return int(f.read().strip() or "1")
    except (OSError, ValueError):
        return 1


def build_failed(rc):
    if rc != 0:
        return True
    try:
        return os.path.exists(ERROR_LOG) and os.path.getsize(ERROR_LOG) > 0
    except OSError:
        return False


def report_failure(msg_id, pct, curr, total, start_time):
    print("\nBuild Failed")
    send_msg(format_msg("failed", pct, curr, total, start_time), msg_id)
    log_file = ERROR_LOG if os.path.exists(ERROR_LOG) and os.path.getsize(ERROR_LOG) > 0 else CI_LOG
    send_doc(log_file, f"Build log · <code>{DEVICE}</code>")


def report_success(msg_id, pct, curr, total, start_time):
    print("\nBuild Success!")

    files = [
        f for f in Path(OUT_DIR).glob("*.zip")
        if "ota" not in f.name.lower() and f.stat().st_size > 500 * 1024 * 1024
    ]
    if not files:
        send_msg("<b>Build finished but no ROM zip was found.</b>", msg_id)
        return
    rom_zip = max(files, key=lambda f: f.stat().st_mtime)

    send_msg(
        format_msg("started", 100, curr, total, start_time)
        + "\nUploading artifacts, please wait...",
        msg_id,
    )

    rom_links = []
    if PIXELDRAIN_API:
        url = upload_with_retry(upload_pixeldrain, str(rom_zip))
        if url:
            rom_links.append({"text": "📥 PixelDrain", "url": url})
    url = upload_with_retry(upload_gofile, str(rom_zip))
    if url:
        rom_links.append({"text": "📥 GoFile", "url": url})

    keyboard = []
    if rom_links:
        keyboard.append(rom_links)

    image_links = []
    for filename in EXTRA_UPLOAD_FILES:
        file_path = Path(OUT_DIR) / filename
        if file_path.exists() and file_path.stat().st_size > 0:
            url = upload_with_retry(upload_gofile, str(file_path))
            if url:
                image_links.append({"text": f"📥 {filename}", "url": url})
    if image_links:
        keyboard.append(image_links)

    text = format_msg("success", 100, curr, total, start_time,
                      rom_zip.name, rom_zip.stat().st_size / (1024 ** 3))
    send_msg(text, msg_id, {"inline_keyboard": keyboard} if keyboard else None)
    pin_msg(msg_id)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not BOT_TOKEN or not TARGET_CHAT:
        print(f"Missing BOT_TOKEN or chat id. Run ./install.sh or edit {CONFIG_FILE}")
        return 1
    if not CI_LOG or not CI_DONE_FILE:
        print("monitor.py must be started by autohook.sh")
        return 1

    where = f"DM {USER_ID}" if SEND_TO == "dm" else f"group {CHAT_ID}"
    print(f"Monitoring {ROM_NAME} / {DEVICE} (Android {ANDROID_VERSION}, {BUILD_TYPE})")
    print(f"   sending to: {where}")
    print(f"   log: {CI_LOG}")

    if not wait_for_real_build():
        print("No real build detected -- staying silent.")
        return 0

    start_time = time.time()
    msg_id = send_msg(format_msg("started", 0, 0, 0, start_time))

    def handle_exit(signum, frame):
        print("\nInterrupted.")
        send_msg(format_msg("stopped", 0, 0, 0, start_time), msg_id)
        sys.exit(130)

    signal.signal(signal.SIGINT, handle_exit)
    signal.signal(signal.SIGTERM, handle_exit)

    last_text = ""
    last_targets = (0, 0, 0)
    last_update = 0.0
    rate = 0.0
    sample_curr, sample_t = 0, start_time

    while not os.path.exists(CI_DONE_FILE):
        if not launcher_alive():
            print("\nBuild shell is gone -- reporting stopped.")
            send_msg(format_msg("stopped", *last_targets, start_time), msg_id)
            return 0
        pct, curr, total = fetch_progress()
        if total > 0:
            last_targets = (pct, curr, total)
        now = time.time()
        if now - last_update >= UPDATE_INTERVAL:
            dt = now - sample_t
            if dt > 0 and curr > sample_curr:
                inst = (curr - sample_curr) / dt
                rate = inst if rate <= 0 else 0.6 * rate + 0.4 * inst
            sample_curr, sample_t = curr, now
            eta = (total - curr) / rate if (rate > 0 and total > curr) else None
            text = format_msg("started", *last_targets, start_time,
                              rate=rate, eta=eta)
            if text != last_text:
                send_msg(text, msg_id)
                last_text = text
            last_update = now
        time.sleep(1)

    pct, curr, total = last_targets
    rc = read_rc()

    if build_failed(rc):
        report_failure(msg_id, pct, curr, total, start_time)
        return 1

    report_success(msg_id, pct, curr, total, start_time)
    return 0


if __name__ == "__main__":
    sys.exit(main())
