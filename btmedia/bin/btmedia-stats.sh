#!/usr/bin/env bash
# btmedia-stats.sh - analyze btmedia listening history and connection logs.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
    cat <<'EOF'
usage: btmedia-stats.sh <summary|top-artists [N]|top-tracks [N]|players|recent [N]|sessions>
EOF
}

require_history() {
    if [[ ! -s $HISTORY_FILE ]]; then
        echo "No listening history recorded yet ($HISTORY_FILE)."
        exit 0
    fi
}

cmd_summary() {
    require_history
    local total uniq_tracks uniq_artists conns
    total=$(wc -l <"$HISTORY_FILE")
    uniq_tracks=$(awk -F'\t' '{print $3 " - " $4}' "$HISTORY_FILE" | sort -u | wc -l)
    uniq_artists=$(awk -F'\t' '$3 != "" {print $3}' "$HISTORY_FILE" | sort -u | wc -l)
    conns=$(grep -c 'Phone connected' "$LOG_FILE" 2>/dev/null || echo 0)

    printf 'Total plays:    %d\nUnique tracks:  %d\nUnique artists: %d\nPhone sessions: %d\n' \
        "$total" "$uniq_tracks" "$uniq_artists" "$conns"
}

cmd_top_artists() {
    require_history
    local n=${1:-10}
    awk -F'\t' '$3 != "" {print $3}' "$HISTORY_FILE" |
        sort | uniq -c | sort -rn | head -n "$n" |
        awk '{c=$1; $1=""; sub(/^ /, ""); printf "%4d\t%s\n", c, $0}' |
        column -t -s $'\t'
}

cmd_top_tracks() {
    require_history
    local n=${1:-10}
    awk -F'\t' '{printf "%s — %s\n", ($3 ? $3 : "Unknown"), $4}' "$HISTORY_FILE" |
        sort | uniq -c | sort -rn | head -n "$n" |
        awk '{c=$1; $1=""; sub(/^ /, ""); printf "%4d\t%s\n", c, $0}' |
        column -t -s $'\t'
}

cmd_players() {
    require_history
    awk -F'\t' '{c[$2]++; t++} END {for (p in c) printf "%s\t%d\t(%.1f%%)\n", p, c[p], (c[p]*100)/t}' "$HISTORY_FILE" |
        sort -t$'\t' -k2 -rn | column -t -s $'\t'
}

cmd_recent() {
    require_history
    local n=${1:-15}
    tail -n "$n" "$HISTORY_FILE" |
        awk -F'\t' '{printf "%s\t[%s]\t%s — %s\n", $1, $2, ($3 ? $3 : "Unknown"), $4}' |
        column -t -s $'\t'
}

cmd_sessions() {
    [[ -s $LOG_FILE ]] || { echo "No log file yet."; exit 0; }
    grep -E 'Phone (connected|disconnected)|Rejected unauthorized' "$LOG_FILE" | tail -n 20
}

case ${1:-summary} in
    summary)     cmd_summary ;;
    top-artists) cmd_top_artists "${2:-10}" ;;
    top-tracks)  cmd_top_tracks  "${2:-10}" ;;
    players)     cmd_players ;;
    recent)      cmd_recent      "${2:-15}" ;;
    sessions)    cmd_sessions ;;
    -h|--help|help) usage ;;
    *)           usage >&2; exit 2 ;;
esac
