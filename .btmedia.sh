#!/usr/bin/env bash
# btmedia.sh - control Linux media players from an Android phone over Bluetooth.
#
#   phone <--RFCOMM serial--> /dev/rfcomm0 <--btmedia.sh--> mediactl.sh --> playerctl / wpctl
#
# usage:  bash btmedia.sh                 (keep mediactl.sh in the same folder)
#         PHONE_MAC=AA:BB:CC:DD:EE:FF bash btmedia.sh     # accept only your phone
#
# Protocol (one text line per message, fields separated by ASCII 0x1F):
#   Linux -> phone   NOW <status> <position_us> <length_us> <title> <artist> <album>
#                    ART <base64 jpeg>            (empty = no cover)
#                    VOL <percent> <muted 0|1>
#                    PLAYER <name of the active player>
#   phone -> Linux   PLAY_PAUSE | NEXT | PREV | SEEK <sec> | SEEK_FWD | SEEK_BACK
#                    VOL_UP | VOL_DOWN | VOL <percent> | MUTE | STATE
#                    Every command is handed to mediactl.sh, which holds all the logic.

set -u

CH=22                                       # RFCOMM channel advertised over SDP
DEV=/dev/rfcomm0
PHONE_MAC=${PHONE_MAC:-}
US=$'\x1f'                                  # not whitespace, so empty fields survive `read`
CACHE=${XDG_RUNTIME_DIR:-/tmp}/btmedia      # cover cache, lives in RAM on most systems
FMT="{{status}}${US}{{position}}${US}{{mpris:length}}${US}{{title}}${US}{{artist}}${US}{{album}}${US}{{mpris:artUrl}}"
IM=${IM:-}
CTLFILE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/mediactl.sh
LOCK=$CACHE/out.lock

ctl() { bash "$CTLFILE" "$@"; }       # run via bash: works even if the download lost the exec bit

# emit CMD...: run a command that prints ONE whole message while holding a lock.
# The pusher and the command handler both write to the phone; without the lock a long
# ART line could get another message spliced into its middle.
emit() { { flock 9; "$@"; } 9>"$LOCK"; }

now_msg() { printf 'NOW\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$1" "${2:-0}" "${3:-0}" "$4" "$5" "$6"; }

# send_state: volume + active player, asked from mediactl.sh
send_state() {
    local s
    s=$(ctl state 2>/dev/null)
    [[ -n $s ]] && emit printf '%s\n' "$s"
}

# snapshot: one fresh NOW line (a seek does not trigger playerctl --follow)
snapshot() {
    local status pos len title artist album url
    IFS=$US read -r status pos len title artist album url \
        < <(playerctl metadata --format "$FMT" 2>/dev/null) || return 0
    emit now_msg "$status" "$pos" "$len" "$title" "$artist" "$album"
}

# handle_cmd NAME [ARG]: one command from the phone, e.g. PLAY_PAUSE -> mediactl.sh play-pause
handle_cmd() {
    local cmd=${1,,}
    cmd=${cmd//_/-}
    ctl "$cmd" "${2:-}" >/dev/null 2>&1
    case $cmd in seek*) snapshot ;; esac
    send_state
}

# kill a process and everything below it
killtree() {
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done
    kill "$1" 2>/dev/null
}

cleanup() {
    local c
    for c in $(pgrep -P $$ 2>/dev/null); do killtree "$c"; done
    sudo pkill -f "[r]fcomm listen $DEV" 2>/dev/null
    sudo rfcomm release "$DEV" 2>/dev/null
}

# art_for URL -> prints a 400px JPEG as base64. Cached per URL, so a track change
# inside the same album (or a reconnect) costs nothing. Prints nothing on failure.
art_for() {
    local url=$1 key f src
    [[ -n $url ]] || return 0
    key=$(md5sum <<<"$url"); key=${key%% *}
    f=$CACHE/$key.b64
    if [[ ! -s $f ]]; then
        case $url in
            file://*)
                src=${url#file://}
                src=$(printf '%b' "${src//%/\\x}")          # decode %20 etc.
                "$IM" "$src" -thumbnail '400x400>' -quality 80 jpg:- 2>/dev/null |
                    base64 -w0 >"$f" ;;
            http*://*)
                curl -fsL --max-time 5 "$url" 2>/dev/null |
                    "$IM" - -thumbnail '400x400>' -quality 80 jpg:- 2>/dev/null |
                    base64 -w0 >"$f" ;;
        esac
        [[ -s $f ]] || rm -f "$f"
    fi
    [[ -s $f ]] && cat "$f"
    return 0
}

# push: stream player changes to stdout (the phone). Event driven - playerctl
# --follow sleeps until a track, state or player change happens, so idle cost is zero.
push() {
    local status pos len title artist album url art last_url=$'\x01'
    while IFS=$US read -r status pos len title artist album url; do
        emit now_msg "$status" "$pos" "$len" "$title" "$artist" "$album" || return
        if [[ $url != "$last_url" ]]; then          # re-send the cover only when it changed
            last_url=$url
            art=$(art_for "$url")                   # slow part (download + resize) stays outside the lock
            emit printf 'ART\x1f%s\n' "$art" || return
        fi
        send_state                                  # volume + active player
    done < <(playerctl --follow metadata --format "$FMT" 2>/dev/null)
}

# serve: one phone connection, until it drops
serve() {
    local cmd arg pusher
    exec 3<>"$DEV"
    stty -F "$DEV" raw -echo 2>/dev/null
    push >&3 &
    pusher=$!
    echo "phone connected"
    send_state >&3
    while read -r cmd arg <&3; do
        handle_cmd "$cmd" "$arg" >&3
    done
    killtree "$pusher"
    wait "$pusher" 2>/dev/null
    exec 3>&-
    echo "phone disconnected"
}

main() {
    local c rf connected

    for c in playerctl rfcomm sdptool curl base64 md5sum pgrep flock sudo stty; do
        command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
    done
    [[ -n $IM ]] || IM=$(command -v magick || command -v convert) ||
        { echo "missing: imagemagick" >&2; exit 1; }
    [[ -f $CTLFILE ]] || { echo "missing: $CTLFILE (keep mediactl.sh next to btmedia.sh)" >&2; exit 1; }
    mkdir -p "$CACHE"

    trap '' HUP                                 # a tty hangup must not kill us
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    # one password prompt, then keep the sudo ticket fresh while we run
    sudo -v || exit 1
    ( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &

    bluetoothctl power on >/dev/null 2>&1
    playerctld daemon 2>/dev/null               # makes "current player" = last one you used

    # advertise a Serial Port service on channel $CH (once; it persists until bluetoothd restarts)
    sudo sdptool browse local 2>/dev/null | grep -Eq "Channel: $CH( |$)" ||
        sudo sdptool add --channel="$CH" SP >/dev/null ||
        { echo "sdptool failed - is bluetoothd running with --compat?" >&2; exit 1; }

    # a leftover "rfcomm listen" from an earlier run keeps the channel -> "Address already in use".
    # ([r] stops pkill from matching its own sudo parent)
    sudo pkill -f "[r]fcomm listen $DEV" 2>/dev/null
    sleep 0.3

    while true; do
        connected=0
        sudo rfcomm release "$DEV" 2>/dev/null
        echo "waiting for phone on channel $CH ..."
        sudo rfcomm listen "$DEV" "$CH" >/dev/null &     # stderr stays visible: bind errors show up
        rf=$!

        until [[ -c $DEV ]]; do                 # device node appears when a phone connects
            kill -0 "$rf" 2>/dev/null || break
            sleep 0.2
        done

        if [[ -c $DEV ]]; then
            connected=1
            [[ -r $DEV && -w $DEV ]] || sudo chmod 666 "$DEV"
            if [[ -z $PHONE_MAC ]] || sudo rfcomm show "$DEV" 2>/dev/null | grep -qi "$PHONE_MAC"; then
                serve
            else
                echo "rejected a connection from another device"
            fi
        fi

        killtree "$rf"
        wait "$rf" 2>/dev/null
        (( connected )) || sleep 2              # rfcomm failed to start: don't spin
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
