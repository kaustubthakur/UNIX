#!/usr/bin/env bash
# btmedia-daemon.sh - event-driven RFCOMM server bridging Android <-> mediactl.sh.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

FMT="{{status}}${US}{{position}}${US}{{mpris:length}}${US}{{title}}${US}{{artist}}${US}{{album}}${US}{{mpris:artUrl}}${US}{{playerName}}"

ctl() { bash "$BTMEDIA_BIN/mediactl.sh" "$@"; }
art() { bash "$BTMEDIA_BIN/btmedia-art.sh" "$@"; }
bt()  { bash "$BTMEDIA_BIN/btmedia-bt.sh" "$@"; }

emit() { { flock 9; "$@"; } 9>"$LOCK_FILE"; }

set_status() { printf '%s\n' "$*" >"$STATUS_FILE"; }

now_msg() {
    printf 'NOW\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
        "$1" "${2:-0}" "${3:-0}" "$4" "$5" "$6"
}

record_play() {
    local player=$1 artist=$2 title=$3 album=$4
    [[ -n $title ]] || return 0
    # Sanitize tabs/newlines to keep TSV clean
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "${player//[$'\t\r\n']/ }" \
        "${artist//[$'\t\r\n']/ }" \
        "${title//[$'\t\r\n']/ }" \
        "${album//[$'\t\r\n']/ }" >>"$HISTORY_FILE"
}

send_state() {
    local s
    s=$(ctl state 2>/dev/null || true)
    [[ -n $s ]] && emit printf '%s\n' "$s"
}

snapshot() {
    local status pos len title artist album url player
    IFS=$US read -r status pos len title artist album url player \
        < <(playerctl metadata --format "$FMT" 2>/dev/null) || return 0
    emit now_msg "$status" "$pos" "$len" "$title" "$artist" "$album"
}

handle_cmd() {
    local cmd=${1,,} arg=${2:-}
    cmd=${cmd//_/-}
    log_debug "RX cmd: $cmd $arg"
    ctl "$cmd" "$arg" >/dev/null 2>&1 || true
    case $cmd in seek*) snapshot ;; esac
    send_state
}

push_media() {
    local status pos len title artist album url player img
    local last_url=$'\x01' last_track=""
    while IFS=$US read -r status pos len title artist album url player; do
        emit now_msg "$status" "$pos" "$len" "$title" "$artist" "$album" || return
        if [[ $status == "Playing" && "$artist|$title" != "$last_track" ]]; then
            last_track="$artist|$title"
            record_play "${player%%.instance*}" "$artist" "$title" "$album"
        fi
        if [[ $url != "$last_url" ]]; then
            last_url=$url
            img=$(art "$url")
            emit printf 'ART\x1f%s\n' "$img" || return
        fi
        send_state
    done < <(playerctl --follow metadata --format "$FMT" 2>/dev/null)
}

push_volume() {
    local line
    while IFS= read -r line; do
        emit printf '%s\n' "$line" || return
    done < <(ctl vol-watch 2>/dev/null)
}

serve() {
    local peer=$1 cmd arg p_media p_vol
    exec 3<>"$DEV"
    stty -F "$DEV" raw -echo 2>/dev/null || true

    set_status "connected:$peer"
    log_info "Phone connected ($peer)"

    push_media  >&3 & p_media=$!
    push_volume >&3 & p_vol=$!
    send_state  >&3

    while read -r cmd arg <&3; do
        [[ -n $cmd ]] && handle_cmd "$cmd" "$arg" >&3
    done

    killtree "$p_media"
    killtree "$p_vol"
    wait "$p_media" "$p_vol" 2>/dev/null || true
    exec 3>&-
    log_info "Phone disconnected ($peer)"
    set_status "waiting"
}

cleanup() {
    local c
    for c in $(pgrep -P $$ 2>/dev/null || true); do killtree "$c"; done
    bt cleanup
    rm -f "$PID_FILE" "$STATUS_FILE"
    log_info "Daemon stopped"
}

reload_handler() {
    log_info "Received SIGUSR1 — reloading config"
    load_config
}

main() {
    init_dirs
    require_cmds playerctl rfcomm sdptool curl base64 sha256sum pgrep flock sudo stty || exit 1

    # Single-instance guard
    if [[ -f $PID_FILE ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log_error "btmedia-daemon is already running (PID $(cat "$PID_FILE"))"
        exit 1
    fi
    echo $$ >"$PID_FILE"

    trap '' HUP
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    trap reload_handler USR1

    sudo -v || exit 1
    ( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null || true; sleep 50; done ) &

    playerctld daemon 2>/dev/null || true
    bt advertise || exit 1
    bt cleanup
    sleep 0.3

    local rf connected peer
    while true; do
        connected=0
        sudo rfcomm release "$DEV" 2>/dev/null || true
        set_status "waiting"
        log_info "Listening on RFCOMM channel $CH ($DEV)"

        sudo rfcomm listen "$DEV" "$CH" >/dev/null &
        rf=$!

        until [[ -c $DEV ]]; do
            kill -0 "$rf" 2>/dev/null || break
            sleep 0.2
        done

        if [[ -c $DEV ]]; then
            connected=1
            [[ -r $DEV && -w $DEV ]] || sudo chmod 666 "$DEV"
            peer=$(sudo rfcomm show "$DEV" 2>/dev/null | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | sed -n '2p' || echo "unknown")
            if [[ -z $PHONE_MAC || ${peer^^} == "${PHONE_MAC^^}" ]]; then
                serve "$peer"
            else
                log_warn "Rejected unauthorized device: $peer"
            fi
        fi

        killtree "$rf"
        wait "$rf" 2>/dev/null || true
        (( connected )) || sleep 2
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
