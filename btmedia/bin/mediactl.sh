#!/usr/bin/env bash
# mediactl.sh - stateless CLI controller for MPRIS players and system volume.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

pc() { playerctl "$@" 2>/dev/null; }
is_num() { [[ ${1:-} =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
is_int() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

if   command -v wpctl >/dev/null 2>&1; then AUDIO=wpctl
elif command -v pactl >/dev/null 2>&1; then AUDIO=pactl
else AUDIO=none
fi

usage() {
    cat <<'EOF'
usage: mediactl.sh <command> [value]
  play-pause | play | pause | next | prev
  seek-fwd [sec] | seek-back [sec] | seek <sec>
  vol-up [pct] | vol-down [pct] | vol [pct] | mute
  info | player | players | player-next | state | vol-watch
EOF
}

vol_get() {
    local out v pct m
    case $AUDIO in
        wpctl)
            out=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null) || return 1
            v=${out#Volume: }; v=${v%% *}
            pct=$(awk -v v="$v" 'BEGIN { printf "%d", v * 100 + 0.5 }')
            [[ $out == *MUTED* ]] && m=1 || m=0 ;;
        pactl)
            out=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null) || return 1
            pct=$(grep -o '[0-9]\+%' <<<"$out" | head -1); pct=${pct%\%}
            [[ $(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null) == *yes* ]] && m=1 || m=0 ;;
        *) return 1 ;;
    esac
    echo "${pct:-0} $m"
}

vol_set() {
    local n=$1
    (( n > 100 )) && n=100
    (( n < 0 )) && n=0
    case $AUDIO in
        wpctl) wpctl set-volume @DEFAULT_AUDIO_SINK@ "${n}%" ;;
        pactl) pactl set-sink-volume @DEFAULT_SINK@ "${n}%" ;;
        *) return 1 ;;
    esac
}

vol_change() {
    local cur mute n
    read -r cur mute < <(vol_get) || return 1
    n=$(( cur + $1 ))
    (( n < 0 )) && n=0
    vol_set "$n"
}

mute_toggle() {
    case $AUDIO in
        wpctl) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
        pactl) pactl set-sink-mute @DEFAULT_SINK@ toggle ;;
        *) return 1 ;;
    esac
}

show_vol() {
    local pct mute
    read -r pct mute < <(vol_get) || { echo "no audio backend" >&2; return 1; }
    echo "${pct}%$([[ $mute == 1 ]] && echo ' (muted)')"
}

active_player() {
    local p
    p=$(pc metadata --format '{{playerName}}' || true)
    if [[ -z $p || $p == playerctld ]]; then
        p=$(pc -l | grep -vx playerctld | head -1 || true)
    fi
    printf '%s\n' "$p"
}

info() {
    local pct mute
    pc metadata --format $'Player:  {{playerName}}\nStatus:  {{status}}\nTitle:   {{title}}\nArtist:  {{artist}}\nAlbum:   {{album}}\nTime:    {{duration(position)}} / {{duration(mpris:length)}}' ||
        echo "No media player is running."
    if read -r pct mute < <(vol_get); then
        echo "Volume:  ${pct}%$([[ $mute == 1 ]] && echo ' (muted)')"
    fi
}

state() {
    local pct mute
    if read -r pct mute < <(vol_get); then
        printf 'VOL\x1f%s\x1f%s\n' "$pct" "$mute"
    fi
    printf 'PLAYER\x1f%s\n' "$(active_player)"
}

# Stream VOL<US><pct><US><muted> whenever the system sink changes
vol_watch() {
    local last="" cur pct mute
    emit_if_changed() {
        read -r pct mute < <(vol_get) || return 0
        cur="$pct $mute"
        if [[ $cur != "$last" ]]; then
            last=$cur
            printf 'VOL\x1f%s\x1f%s\n' "$pct" "$mute"
        fi
    }

    if command -v pactl >/dev/null 2>&1; then
        # Works natively on PipeWire (via pipewire-pulse) and PulseAudio
        while read -r line; do
            [[ $line == *"on sink"* ]] && emit_if_changed
        done < <(pactl subscribe 2>/dev/null)
    else
        while sleep 1; do
            emit_if_changed
        done
    fi
}

cmd=${1:-help}
arg=${2:-}

case $cmd in
    play-pause)  pc play-pause ;;
    play)        pc play ;;
    pause)       pc pause ;;
    next)        pc next ;;
    prev)        pc previous ;;
    seek-fwd)    is_num "${arg:-$SEEK_STEP}" && pc position "${arg:-$SEEK_STEP}+" ;;
    seek-back)   is_num "${arg:-$SEEK_STEP}" && pc position "${arg:-$SEEK_STEP}-" ;;
    seek)        is_num "$arg" && pc position "$arg" ;;
    vol-up)      is_int "${arg:-$VOL_STEP}" && vol_change "+${arg:-$VOL_STEP}" ;;
    vol-down)    is_int "${arg:-$VOL_STEP}" && vol_change "-${arg:-$VOL_STEP}" ;;
    mute)        mute_toggle ;;
    vol)
        if   [[ -z $arg ]];  then show_vol
        elif is_int "$arg";  then vol_set "$arg"
        else usage >&2; exit 2
        fi ;;
    info)        info ;;
    player)      active_player ;;
    players)     pc -l | grep -vx playerctld || true ;;
    player-next) playerctld shift 2>/dev/null || true ;;
    state)       state ;;
    vol-watch)   vol_watch ;;
    help|-h|--help) usage ;;
    *)           usage >&2; exit 2 ;;
esac
