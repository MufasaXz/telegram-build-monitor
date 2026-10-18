# shellcheck shell=bash
# ~/.ci/autohook.sh
#
# Auto-starts the build monitor (~/.ci/monitor.py) whenever a real AOSP build
# is launched with `m`, `mka` or Axion's `ax`.  ROM-agnostic: it does not
# assume how the ROM defines those commands, it captures whatever exists
# (function or binary) and wraps it.
#
# Sourced from ~/.bashrc.  The wrapper installs itself lazily on the first
# prompt *after* build/envsetup.sh has been sourced, so there is nothing to run
# manually: just `source build/envsetup.sh`, `lunch <combo>` (or `axion
# <device>` on Axion), then `m bacon` (or `ax -br`).
#
# Disable for a shell with:  export _CI_DISABLED=1

_CI_DIR="${CI_HOME:-$HOME/.ci}"
_CI_STATE="$_CI_DIR/state"

# Use the interpreter the installer verified. An envsetup'd shell can put a
# different python3 first in PATH (AOSP prebuilts), which may not have requests.
_ci_python() {
    local py="python3" p
    if [ -r "$_CI_DIR/config.env" ]; then
        p=$(sed -n 's/^PYTHON=//p' "$_CI_DIR/config.env" 2>/dev/null | tail -n 1)
        [ -n "$p" ] && [ -x "$p" ] && py="$p"
    fi
    printf '%s' "$py"
}

# ---------------------------------------------------------------------------
# Install (once per shell, after envsetup)
# ---------------------------------------------------------------------------
_ci_install() {
    # Reaching a prompt means no build is running in this shell, so any leftover
    # dispatch/monitor bookkeeping is stale.  A build interrupted with Ctrl-C can
    # leave _CI_DISPATCHING set, and _ci_run then treats every later `m`/`mka` as
    # a nested call and silently skips the monitor -- so clear it here, every
    # prompt.  (Nested calls only happen while a build runs, never at a prompt.)
    if [ -n "$_CI_DISPATCHING" ] || [ -n "$_CI_MONITOR_PID" ]; then
        # A monitor left over from an interrupted build would loop forever
        # waiting for a .done file that never comes; let it post and exit.
        if [ -n "$_CI_MONITOR_PID" ] && kill -0 "$_CI_MONITOR_PID" 2>/dev/null; then
            kill -TERM "$_CI_MONITOR_PID" 2>/dev/null
        fi
        unset _CI_DISPATCHING _CI_MONITOR_PID _CI_LOG _CI_RC_FILE _CI_DONE_FILE
    fi

    # Only meaningful inside an envsetup'd Android tree.
    [ -n "$ANDROID_BUILD_TOP" ] || return 0
    [ -d "$ANDROID_BUILD_TOP/build" ] || return 0

    # Already wrapped and still intact?  Every build command present in this
    # shell must be our wrapper -- a re-sourced shell can have m/mka wrapped by
    # an older hook while ax (Axion trees) is still bare, which must not pass.
    if [ -n "$_CI_INSTALLED" ]; then
        local _need=0 _n
        for _n in m mka ax; do
            if { declare -F "$_n" >/dev/null 2>&1 || command -v "$_n" >/dev/null 2>&1; } \
               && ! declare -f "$_n" 2>/dev/null | grep -q '_ci_run'; then
                _need=1
            fi
        done
        [ "$_need" = 0 ] && return 0
    fi

    local name kind
    for name in m mka ax; do
        # Already our wrapper (re-sourced shell): keep the saved original.
        # Re-copying here would save the wrapper as its own original and the
        # next build would recurse.
        if declare -f "$name" 2>/dev/null | grep -q '_ci_run'; then
            continue
        fi
        if declare -F "$name" >/dev/null 2>&1; then
            # Copy the original function under a private name.
            eval "$(declare -f "$name" | sed "1s/^${name} /_ci_orig_${name} /")"
            kind=function
        elif command -v "$name" >/dev/null 2>&1; then
            kind=binary
        else
            kind=none
        fi
        printf -v "_CI_KIND_${name}" '%s' "$kind"
    done

    # Nothing buildable in this tree yet.
    if [ "${_CI_KIND_m:-none}" = none ] && [ "${_CI_KIND_mka:-none}" = none ] \
       && [ "${_CI_KIND_ax:-none}" = none ]; then
        return 0
    fi

    # (Re)define wrappers only for commands that are not already wrapped.
    for name in m mka ax; do
        local kindvar="_CI_KIND_${name}"
        [ "${!kindvar:-none}" = none ] && continue
        declare -f "$name" 2>/dev/null | grep -q '_ci_run' && continue
        case "$name" in
            m)   m()   { _ci_run m   "$@"; } ;;
            mka) mka() { _ci_run mka "$@"; } ;;
            ax)  ax()  { _ci_run ax  "$@"; } ;;
        esac
    done

    _CI_INSTALLED=1
    if [ -n "$_CI_DEBUG_HOOKED" ]; then
        trap - DEBUG 2>/dev/null || true
        unset _CI_DEBUG_HOOKED
    fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
_ci_run() {
    local name="$1"; shift

    # Nested interception (e.g. mka -> m, ax -> m): just run the real command once.
    if [ -n "$_CI_DISPATCHING" ]; then
        _ci_call_orig "$name" "$@"
        return $?
    fi

    if _ci_should_monitor "$@"; then
        _ci_launch_monitor "$name" "$@"
    fi

    local rc
    if [ -n "$_CI_MONITOR_PID" ]; then
        export _CI_DISPATCHING=1
        _ci_call_orig "$name" "$@" 2>&1 | tee -a "$_CI_LOG"
        rc=${PIPESTATUS[0]}
        unset _CI_DISPATCHING
        _ci_finish_monitor "$rc"
    else
        _ci_call_orig "$name" "$@"
        rc=$?
    fi
    return $rc
}

_ci_call_orig() {
    local name="$1"; shift
    local kindvar="_CI_KIND_${name}"
    if [ "${!kindvar}" = function ]; then
        "_ci_orig_${name}" "$@"
    else
        command "$name" "$@"
    fi
}

# Cheap pre-filter. The real "is this actually building?" check happens in the
# monitor (it waits for a soong/ninja process), so this only screens the
# obvious non-builds.
_ci_should_monitor() {
    [ -n "$_CI_DISABLED" ] && return 1
    local a
    for a in "$@"; do
        case "$a" in
            -h|--help|help|--version|-v) return 1 ;;
        esac
    done
    return 0
}

# ---------------------------------------------------------------------------
# Monitor lifecycle
# ---------------------------------------------------------------------------
_ci_launch_monitor() {
    local name="$1"; shift
    mkdir -p "$_CI_STATE" 2>/dev/null

    local ts; ts=$(date +%Y%m%d-%H%M%S)
    _CI_LOG="$_CI_STATE/build-$ts.log"
    _CI_RC_FILE="$_CI_STATE/build-$ts.rc"
    _CI_DONE_FILE="$_CI_STATE/build-$ts.done"
    : > "$_CI_LOG"
    rm -f "$_CI_RC_FILE" "$_CI_DONE_FILE"

    # The shell may have cd'd into another ROM tree since envsetup. Resolve the
    # tree from the current directory when gettop is available, otherwise the
    # monitor would watch the old tree and never see the new build.
    local top="$ANDROID_BUILD_TOP"
    if command -v gettop >/dev/null 2>&1; then
        local t
        t=$(gettop 2>/dev/null) || true
        [ -n "$t" ] && top="$t"
    fi

    # Give the ROM a fresh error log for this build (used by some ROMs).
    rm -f "$top/out/error.log" 2>/dev/null

    # Device comes straight from TARGET_PRODUCT (clover_raphael -> raphael); the
    # Android version is resolved by the monitor from the repo manifest.
    #
    # Deliberately NO get_build_var here: it invokes soong, which takes the out
    # directory lock.  Called twice at once (or while the tree is busy) it can
    # block for minutes or deadlock outright, stalling the build before it even
    # starts.  Everything the monitor needs is available without it.
    local device="${TARGET_PRODUCT##*_}"

    # Telegram shows the target; for ax include the driver name so `-br` alone
    # is not cryptic (bare `ax` also builds, so this is never empty).
    local targets="$*"
    [ "$name" = ax ] && targets="ax${targets:+ $targets}"

    local py; py=$(_ci_python)

    CI_TOP="$top" \
    CI_PRODUCT="${TARGET_PRODUCT:-}" \
    CI_DEVICE="$device" \
    CI_VARIANT="${TARGET_BUILD_VARIANT:-}" \
    CI_RELEASE="${TARGET_RELEASE:-}" \
    CI_ANDROID_VERSION="" \
    CI_TARGETS="$targets" \
    CI_LOG="$_CI_LOG" \
    CI_RC_FILE="$_CI_RC_FILE" \
    CI_DONE_FILE="$_CI_DONE_FILE" \
    nohup "$py" "$_CI_DIR/monitor.py" >"$_CI_STATE/monitor-$ts.out" 2>&1 &

    _CI_MONITOR_PID=$!
    # Detach so bash does not print a "[1]+ Done ..." notice at the next prompt.
    disown "$_CI_MONITOR_PID" 2>/dev/null || true
    return 0
}

_ci_finish_monitor() {
    local rc="$1"
    [ -n "$_CI_RC_FILE" ]   && printf '%s\n' "$rc" > "$_CI_RC_FILE"
    [ -n "$_CI_DONE_FILE" ] && : > "$_CI_DONE_FILE"
    unset _CI_LOG _CI_RC_FILE _CI_DONE_FILE _CI_MONITOR_PID
}

# ---------------------------------------------------------------------------
# Hook into the prompt so the wrapper installs itself after envsetup.
# ---------------------------------------------------------------------------
if [ -z "$_CI_PROMPT_HOOKED" ]; then
    case ";$PROMPT_COMMAND;" in
        *";_ci_install;"*) ;;
        *) PROMPT_COMMAND="_ci_install${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
    esac
    _CI_PROMPT_HOOKED=1
fi

# Also try immediately, in case envsetup was already sourced.
_ci_install

# If envsetup and the build are pasted as one line, no prompt runs between
# them. This temporary DEBUG trap installs the wrappers before the next
# command and removes itself once they are in place.
_ci_debug_install() {
    [ -n "$_CI_INSTALLED" ] && return 0
    [ -n "$_CI_DEBUG_BUSY" ] && return 0
    _CI_DEBUG_BUSY=1
    _ci_install || true
    unset _CI_DEBUG_BUSY
    return 0
}
if [ -z "$_CI_INSTALLED" ] && [ -z "$_CI_DEBUG_HOOKED" ] && [ -z "$(trap -p DEBUG)" ]; then
    _CI_DEBUG_HOOKED=1
    trap '_ci_debug_install' DEBUG
fi
