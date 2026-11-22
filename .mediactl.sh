#!/usr/bin/env bash
# mediactl.sh - one media command per call.
# Use it directly in a terminal, or let btmedia.sh call it for the phone.
#
#   mediactl.sh play-pause | play | pause | next | prev
#   mediactl.sh seek-fwd [sec] | seek-back [sec] | seek <sec>     (default step 10 s)
#   mediactl.sh vol-up [pct] | vol-down [pct] | vol [pct] | mute   (default step 5 %)
#   mediactl.sh info | player | players | state
#
# Tunables:  VOL_STEP=5  SEEK_STEP=10

set -u

VOL_STEP=${VOL_STEP:-5}
SEEK_STEP=${SEEK_STEP:-10}
US=$'\x1f'                       # field separator used on the phone link

pc() { playerctl "$@" 2>/dev/null; }
is_num() { [[ ${1:-} =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
is_int() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

usage() {
    cat <<'EOF'
usage: mediactl.sh <command> [value]
  play-pause | play | pause | next | prev
  seek-fwd [sec] | seek-back [sec] | seek <sec>      (default step 10 s)
  vol-up [pct] | vol-down [pct] | vol [pct] | mute   (default step 5 %)
  info        everything about what is playing
  player      the player that receives your commands
  players     every running player
EOF
}

# ---- system volume: PipeWire (wpctl) or PulseAudio / pipewire-pulse (pactl) ----------
# Player volume is not used on purpose: browsers ignore it, system volume always works.

if   command -v wpctl >/dev/null; then AUDIO=wpctl
elif command -v pactl >/dev/null; then AUDIO=pactl
else AUDIO=none
fi

# vol_get -> prints "<percent> <muted 0|1>"
vol_get() {
    local out v pct m
    case $AUDIO in
        wpctl)
            out=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null) || return 1
            v=${out#Volume: }; v=${v%% *}                        # "0.45 [MUTED]" -> 0.45
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

# vol_set <percent>  (clamped to 100 so keys can never blast the speakers)
vol_set() {
    local n=$1
    (( n > 100 )) && n=100
    case $AUDIO in
        wpctl) wpctl set-volume @DEFAULT_AUDIO_SINK@ "$n%" ;;
        pactl) pactl set-sink-volume @DEFAULT_SINK@ "$n%" ;;
        *) return 1 ;;
    esac
}

# vol_change +5 | -5
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
    read -r pct mute < <(vol_get) || { echo "no audio backend (install wireplumber or pulseaudio-utils)" >&2; return 1; }
    echo "${pct}%$([[ $mute == 1 ]] && echo ' (muted)')"
}

# ---- players ---------------------------------------------------------------------------

# the player playerctl will talk to (playerctld keeps "most recently used" first)
active_player() {
    local p
    p=$(pc metadata --format '{{playerName}}')
    if [[ -z $p || $p == playerctld ]]; then
        p=$(pc -l | grep -vx playerctld | head -1)
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

# state: the two status lines btmedia.sh forwards to the phone
state() {
    local pct mute
    if read -r pct mute < <(vol_get); then
        printf 'VOL\x1f%s\x1f%s\n' "$pct" "$mute"
    fi
    printf 'PLAYER\x1f%s\n' "$(active_player)"
}

# ---- dispatcher: this case statement is also the whitelist of allowed commands -----------

cmd=${1:-help}
arg=${2:-}

case $cmd in
    play-pause) pc play-pause ;;
    play)       pc play ;;
    pause)      pc pause ;;
    next)       pc next ;;
    prev)       pc previous ;;
    seek-fwd)   is_num "${arg:-$SEEK_STEP}" && pc position "${arg:-$SEEK_STEP}+" ;;
    seek-back)  is_num "${arg:-$SEEK_STEP}" && pc position "${arg:-$SEEK_STEP}-" ;;
    seek)       is_num "$arg" && pc position "$arg" ;;
    vol-up)     is_int "${arg:-$VOL_STEP}" && vol_change "+${arg:-$VOL_STEP}" ;;
    vol-down)   is_int "${arg:-$VOL_STEP}" && vol_change "-${arg:-$VOL_STEP}" ;;
    mute)       mute_toggle ;;
    vol)
        if   [[ -z $arg ]];  then show_vol
        elif is_int "$arg";  then vol_set "$arg"
        else usage; exit 2
        fi ;;
    info)       info ;;
    player)     active_player ;;
    players)    pc -l | grep -vx playerctld ;;
    state)      state ;;
    help|-h|--help) usage ;;
    *)          usage >&2; exit 2 ;;
esac
