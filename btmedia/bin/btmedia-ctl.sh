#!/usr/bin/env bash
# btmedia-ctl.sh - manage the btmedia daemon lifecycle and diagnostics.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
init_dirs

usage() {
    cat <<'EOF'
usage: btmedia-ctl.sh <command>
  start [-f]   Start daemon in background (-f for foreground)
  stop         Stop running daemon cleanly
  restart      Restart daemon
  reload       Send SIGUSR1 to reload btmedia.conf live
  status       Show daemon PID, uptime, link state, and current track
  logs [-n N]  Follow daemon logs (or print last N lines)
  doctor       Verify all packages, audio backend, and BlueZ --compat
EOF
}

is_running() {
    [[ -f $PID_FILE ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

cmd_start() {
    if is_running; then
        echo "btmedia is already running (PID $(cat "$PID_FILE"))"
        return 0
    fi
    sudo -v || exit 1
    if [[ ${1:-} == "-f" ]]; then
        exec bash "$BTMEDIA_BIN/btmedia-daemon.sh"
    else
        nohup bash "$BTMEDIA_BIN/btmedia-daemon.sh" >/dev/null 2>&1 &
        sleep 0.5
        if is_running; then
            echo "btmedia started (PID $(cat "$PID_FILE"))"
        else
            echo "Failed to start; inspect logs with: btmedia-ctl.sh logs -n 20" >&2
            exit 1
        fi
    fi
}

cmd_stop() {
    if ! is_running; then
        echo "btmedia is not running"
        return 0
    fi
    local pid
    pid=$(cat "$PID_FILE")
    kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..20}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    echo "btmedia stopped"
}

cmd_status() {
    if is_running; then
        local pid uptime state
        pid=$(cat "$PID_FILE")
        uptime=$(ps -o etime= -p "$pid" 2>/dev/null | xargs)
        state=$(cat "$STATUS_FILE" 2>/dev/null || echo "unknown")
        printf 'Service: active (PID %s, up %s)\nLink:    %s\n' "$pid" "$uptime" "$state"
    else
        printf 'Service: inactive\n'
    fi
    echo "---"
    bash "$BTMEDIA_BIN/mediactl.sh" info
}

cmd_doctor() {
    local ok=0
    echo "=== Dependency Check ==="
    require_cmds playerctl rfcomm sdptool bluetoothctl curl base64 sha256sum flock stty awk column || ok=1
    if command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
        log_info "ImageMagick OK"
    else
        log_error "Missing ImageMagick (Arch: pacman -S imagemagick)"
        ok=1
    fi
    if command -v wpctl >/dev/null 2>&1 || command -v pactl >/dev/null 2>&1; then
        log_info "Audio backend OK ($(command -v wpctl || command -v pactl))"
    else
        log_error "No wpctl or pactl found"
        ok=1
    fi
    echo
    echo "=== Bluetooth Check ==="
    bash "$BTMEDIA_BIN/btmedia-bt.sh" check || ok=1
    echo
    echo "=== Cache Check ==="
    bash "$BTMEDIA_BIN/btmedia-art.sh" --stats
    return "$ok"
}

case ${1:-help} in
    start)   cmd_start "${2:-}" ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; sleep 0.3; cmd_start "${2:-}" ;;
    reload)  is_running && kill -USR1 "$(cat "$PID_FILE")" && echo "Config reloaded" || echo "Not running" ;;
    status)  cmd_status ;;
    logs)
        touch "$LOG_FILE"
        if [[ ${2:-} == "-n" && -n ${3:-} ]]; then tail -n "$3" "$LOG_FILE"
        else tail -f "$LOG_FILE"
        fi ;;
    doctor)  cmd_doctor ;;
    -h|--help|help) usage ;;
    *)       usage >&2; exit 2 ;;
esac
