#!/usr/bin/env bash
# One-step installer. Installs the monitor to ~/.ci, asks for the bot token,
# finds your DM or group, sends a test message and hooks ~/.bashrc.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="${CI_HOME:-$HOME/.ci}"
CONFIG="$CI_DIR/config.env"

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

PYTHON="${PYTHON:-$(command -v python3 || true)}"
[ -n "$PYTHON" ] || die "python3 is required (sudo apt install python3)"
command -v curl >/dev/null || die "curl is required (sudo apt install curl)"

if ! "$PYTHON" -c 'import requests' 2>/dev/null; then
    say "Installing python3-requests..."
    "$PYTHON" -m pip install --user requests >/dev/null 2>&1 \
        || pip3 install --user requests >/dev/null 2>&1 \
        || die "Could not install requests. Run: sudo apt install python3-requests"
fi
"$PYTHON" -c 'import requests' 2>/dev/null \
    || die "$PYTHON cannot import requests. Run: sudo apt install python3-requests"

mkdir -p "$CI_DIR"

if [ "$(id -u)" -eq 0 ]; then
    say "Warning: running as root. The hook and config will be installed for root."
fi

# Keep values from a previous install.
cfg_get() { [ -f "$CONFIG" ] && sed -n "s/^$1=//p" "$CONFIG" | tail -n 1 || true; }

BOT_TOKEN="${BOT_TOKEN:-$(cfg_get BOT_TOKEN)}"
SEND_TO="${SEND_TO:-$(cfg_get SEND_TO)}"
USER_ID="${USER_ID:-$(cfg_get USER_ID)}"
CHAT_ID="${CHAT_ID:-$(cfg_get CHAT_ID)}"
PIXELDRAIN_API="${PIXELDRAIN_API:-$(cfg_get PIXELDRAIN_API)}"
FIRST_INSTALL=0
[ -f "$CONFIG" ] || FIRST_INSTALL=1

# --- bot token --------------------------------------------------------------
if [ -z "$BOT_TOKEN" ]; then
    say ""
    say "1. Open Telegram and message @BotFather."
    say "2. Send /newbot, pick a name, and copy the token it gives you."
    say ""
    read -r -p "Bot token: " BOT_TOKEN
fi
[ -n "$BOT_TOKEN" ] || die "No token provided."

me="$(curl -s --max-time 20 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" || true)"
bot_user="$(printf '%s' "$me" | "$PYTHON" -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: d = {}
print(d.get("result", {}).get("username", "") if d.get("ok") else "")')"
[ -n "$bot_user" ] || die "Telegram rejected the token: $me"
say "Bot: @$bot_user"

# --- where to send ----------------------------------------------------------
if [ -z "$SEND_TO" ]; then
    say ""
    say "Where should build updates go?"
    say "  1) Your DM"
    say "  2) A group"
    read -r -p "Choose [1/2] (default 1): " choice
    case "${choice:-1}" in
        2|g|group) SEND_TO=group ;;
        *)         SEND_TO=dm ;;
    esac
fi
SEND_TO="$(printf '%s' "$SEND_TO" | tr '[:upper:]' '[:lower:]')"
case "$SEND_TO" in
    dm|group) ;;
    *) die "SEND_TO must be 'dm' or 'group' (got '$SEND_TO')" ;;
esac

# List chats seen by getUpdates. $1 is "private" or "group".
find_chats() {
    curl -s --max-time 20 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" | \
    "$PYTHON" -c '
import json, sys
want = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit()
seen = {}
for update in data.get("result", []):
    msg = update.get("message") or update.get("channel_post") or {}
    chat = msg.get("chat") or {}
    if chat.get("id") is None:
        continue
    is_private = chat.get("type") == "private"
    if (want == "private") != is_private:
        continue
    name = (chat.get("title") or chat.get("username") or
            " ".join(filter(None, [chat.get("first_name"), chat.get("last_name")])) or
            "chat")
    seen[chat["id"]] = name
for cid, name in seen.items():
    print(f"{cid}\t{name}")' "$1"
}

pick_chat() {  # $1 = private|group, $2 = prompt label; sets PICKED
    local found count answer
    found=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        found="$(find_chats "$1")"
        [ -n "$found" ] && break
        sleep 2
    done

    count="$(printf '%s' "$found" | grep -c . || true)"
    if [ "$count" = 1 ]; then
        PICKED="${found%%$'\t'*}"
        say "Found: ${found#*$'\t'} ($PICKED)"
    elif [ "$count" -gt 1 ]; then
        say "Found several:"
        printf '%s\n' "$found" | while IFS=$'\t' read -r id name; do say "  $id  $name"; done
        read -r -p "$2 id to use: " answer
        PICKED="$answer"
    else
        read -r -p "$2 id: " answer
        PICKED="$answer"
    fi
}

if [ "$SEND_TO" = dm ]; then
    if [ -z "$USER_ID" ]; then
        say ""
        say "Open a private chat with @$bot_user, press Start (or send /start),"
        say "then press Enter."
        read -r -p "Press Enter when done... " _
        say "Looking for your DM..."
        pick_chat private "Your user"
        USER_ID="$PICKED"
    fi
    TARGET="$USER_ID"
else
    if [ -z "$CHAT_ID" ]; then
        say ""
        say "Add @$bot_user to your group (make it admin for pinned messages),"
        say "send /start@$bot_user in the group, then press Enter."
        read -r -p "Press Enter when done... " _
        say "Looking for the group..."
        pick_chat group "Group chat"
        CHAT_ID="$PICKED"
    fi
    TARGET="$CHAT_ID"
fi
[ -n "$TARGET" ] || die "No chat id provided."

# --- test message -----------------------------------------------------------
# Use the same Python + requests path the monitor uses, so a working curl but
# broken requests/CA setup is caught now instead of silently failing on builds.
test_out="$("$PYTHON" - "$BOT_TOKEN" "$TARGET" <<'PY'
import sys
import requests

token, chat = sys.argv[1], sys.argv[2]
try:
    resp = requests.post(
        f"https://api.telegram.org/bot{token}/sendMessage",
        json={"chat_id": chat, "text": "✅ telegram-build-monitor is connected"},
        timeout=30,
    )
    data = resp.json()
except Exception as e:
    sys.exit(f"request failed: {e}")
if not data.get("ok"):
    sys.exit(data.get("description", "Telegram rejected the message"))
print("ok")
PY
)" || die "Could not send to $TARGET: $test_out"
say "Test message sent."

# --- optional PixelDrain ----------------------------------------------------
if [ "$FIRST_INSTALL" = 1 ]; then
    say ""
    say "Optional: PixelDrain API key for a second download mirror."
    read -r -p "PixelDrain API key (Enter to skip): " PIXELDRAIN_API || true
fi

# --- write config -----------------------------------------------------------
umask 077
{
    printf 'BOT_TOKEN=%s\n' "$BOT_TOKEN"
    printf 'SEND_TO=%s\n' "$SEND_TO"
    printf 'USER_ID=%s\n' "$USER_ID"
    printf 'CHAT_ID=%s\n' "$CHAT_ID"
    printf 'PIXELDRAIN_API=%s\n' "$PIXELDRAIN_API"
    printf 'PYTHON=%s\n' "$PYTHON"
} > "$CONFIG"
chmod 600 "$CONFIG"

# --- install files + hook ---------------------------------------------------
install -m 755 "$SRC/monitor.py" "$CI_DIR/"
install -m 644 "$SRC/autohook.sh" "$CI_DIR/"

HOOK="[ -r \"$CI_DIR/autohook.sh\" ] && . \"$CI_DIR/autohook.sh\""
touch "$HOME/.bashrc"
for rc in "$HOME/.bashrc" "$HOME/.bash_profile"; do
    [ -e "$rc" ] || continue
    if grep -Eq "^[[:space:]]*[^#].*autohook\.sh" "$rc"; then
        say "Hook already in $rc"
    else
        printf '\n# AOSP build -> Telegram monitor\n%s\n' "$HOOK" >> "$rc"
        say "Hook added to $rc"
    fi
done

say ""
say "Done. Sending updates to: $SEND_TO ($TARGET)"

if bash -ic 'type -t _ci_install >/dev/null 2>&1' >/dev/null 2>&1; then
    say "Hook: OK (loads in new shells)"
else
    say "Hook: NOT loading in a new shell."
    say "Make sure this line is in ~/.bashrc:"
    say "  $HOOK"
fi

say ""
say "IMPORTANT: a terminal that was already open before this install does not"
say "have the hook yet. In that terminal run:"
say "  source ~/.bashrc"
say ""
say "Then build normally:"
say "  source build/envsetup.sh && lunch <combo> && mka bacon"
