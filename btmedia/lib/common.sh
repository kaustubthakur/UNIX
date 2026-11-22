# Shared helpers sourced by all btmedia scripts.

set -uo pipefail

# Resolve project root even when invoked via symlink in ~/.local/bin
BTMEDIA_LIB_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
BTMEDIA_ROOT=$(dirname "$BTMEDIA_LIB_DIR")
BTMEDIA_BIN="$BTMEDIA_ROOT/bin"

CONFIG_DEFAULT="$BTMEDIA_ROOT/config/btmedia.conf"
CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/btmedia/btmedia.conf"

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/btmedia"
CACHE_DIR="$RUNTIME_DIR/art"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/btmedia"

LOG_FILE="$STATE_DIR/btmedia.log"
HISTORY_FILE="$STATE_DIR/history.tsv"
PID_FILE="$RUNTIME_DIR/btmedia.pid"
STATUS_FILE="$RUNTIME_DIR/status"
LOCK_FILE="$RUNTIME_DIR/out.lock"

US=$'\x1f'                              # ASCII Unit Separator (0x1F)

load_config() {
    # Defaults first, then user file, while preserving explicit env overrides
    local env_mac=${PHONE_MAC-} env_ch=${CH-} env_vol=${VOL_STEP-} env_seek=${SEEK_STEP-}
    # shellcheck disable=SC1090
    [[ -f $CONFIG_DEFAULT ]] && source "$CONFIG_DEFAULT"
    # shellcheck disable=SC1090
    [[ -f $CONFIG_USER ]] && source "$CONFIG_USER"

    [[ -n $env_mac  ]] && PHONE_MAC=$env_mac
    [[ -n $env_ch   ]] && CH=$env_ch
    [[ -n $env_vol  ]] && VOL_STEP=$env_vol
    [[ -n $env_seek ]] && SEEK_STEP=$env_seek
    return 0
}

init_dirs() {
    mkdir -p "$RUNTIME_DIR" "$CACHE_DIR" "$STATE_DIR"
}

_log_rank() {
    case ${1:-INFO} in
        DEBUG) echo 0 ;; INFO) echo 1 ;; WARN) echo 2 ;; ERROR) echo 3 ;; *) echo 1 ;;
    esac
}

log_msg() {
    local level=$1; shift
    local cur req ts color="" reset=""
    cur=$(_log_rank "${LOG_LEVEL:-INFO}")
    req=$(_log_rank "$level")
    (( req < cur )) && return 0

    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ -t 2 ]]; then
        reset=$'\033[0m'
        case $level in
            DEBUG) color=$'\033[36m' ;;
            INFO)  color=$'\033[32m' ;;
            WARN)  color=$'\033[33m' ;;
            ERROR) color=$'\033[31m' ;;
        esac
    fi
    printf '%s[%s] [%-5s]%s %s\n' "$color" "$ts" "$level" "$reset" "$*" >&2
    [[ -d $STATE_DIR ]] && printf '[%s] [%-5s] %s\n' "$ts" "$level" "$*" >>"$LOG_FILE"
}

log_debug() { log_msg DEBUG "$@"; }
log_info()  { log_msg INFO  "$@"; }
log_warn()  { log_msg WARN  "$@"; }
log_error() { log_msg ERROR "$@"; }

require_cmds() {
    local missing=() c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} > 0 )); then
        log_error "Missing required commands: ${missing[*]}"
        return 1
    fi
}

# Recursively terminate a process and all descendants
killtree() {
    local pid=${1:-} child
    [[ -n $pid ]] || return 0
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
        killtree "$child"
    done
    kill "$pid" 2>/dev/null || true
}

load_config
