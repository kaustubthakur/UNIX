#!/usr/bin/env bash
# btmedia-art.sh - fetch, resize, base64-encode, and cache MPRIS cover art.
#
# Usage:
#   btmedia-art.sh <url>          Print base64 JPEG to stdout (cached)
#   btmedia-art.sh --prune        Evict oldest entries if cache exceeds CACHE_MAX_MB
#   btmedia-art.sh --stats        Show cache item count and disk usage
#   btmedia-art.sh --clear        Empty the art cache

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
init_dirs

IM=${IM:-$(command -v magick || command -v convert || true)}

usage() {
    cat <<'EOF'
usage: btmedia-art.sh <url | --prune | --stats | --clear>
EOF
}

prune_cache() {
    local max_kb=$(( ${CACHE_MAX_MB:-20} * 1024 ))
    local cur_kb oldest
    cur_kb=$(du -sk "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
    (( ${cur_kb:-0} <= max_kb )) && return 0

    log_debug "Pruning art cache (${cur_kb}KB > ${max_kb}KB)"
    # Delete oldest accessed .b64 files until under threshold
    while (( cur_kb > max_kb )); do
        oldest=$(find "$CACHE_DIR" -maxdepth 1 -name '*.b64' -printf '%A@ %p\n' 2>/dev/null |
            sort -n | head -1 | cut -d' ' -f2-)
        [[ -n $oldest ]] || break
        rm -f "$oldest"
        cur_kb=$(du -sk "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
    done
}

fetch_art() {
    local url=${1:-} key f src tmp
    [[ -n $url ]] || return 0
    [[ -n $IM  ]] || { log_error "ImageMagick (magick/convert) not found"; return 1; }

    key=$(printf '%s' "$url" | sha256sum | awk '{print $1}')
    f="$CACHE_DIR/$key.b64"

    if [[ ! -s $f ]]; then
        tmp="$f.tmp.$$"
        case $url in
            file://*)
                src=${url#file://}
                src=$(printf '%b' "${src//%/\\x}")
                "$IM" "$src" -thumbnail "${ART_SIZE:-400x400>}" -quality "${ART_QUALITY:-80}" jpg:- 2>/dev/null |
                    base64 -w0 >"$tmp" ;;
            http://*|https://*)
                curl -fsL --max-time 5 "$url" 2>/dev/null |
                    "$IM" - -thumbnail "${ART_SIZE:-400x400>}" -quality "${ART_QUALITY:-80}" jpg:- 2>/dev/null |
                    base64 -w0 >"$tmp" ;;
            *)
                return 0 ;;
        esac
        if [[ -s $tmp ]]; then
            mv -f "$tmp" "$f"
            prune_cache &
        else
            rm -f "$tmp"
        fi
    else
        touch -a "$f" 2>/dev/null || true
    fi

    [[ -s $f ]] && cat "$f"
    return 0
}

case ${1:-} in
    --prune) prune_cache ;;
    --clear) rm -f "$CACHE_DIR"/*.b64; log_info "Art cache cleared" ;;
    --stats)
        count=$(find "$CACHE_DIR" -maxdepth 1 -name '*.b64' 2>/dev/null | wc -l)
        size=$(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
        printf 'Cache dir: %s\nEntries:   %d\nSize:      %s (limit: %dM)\n' \
            "$CACHE_DIR" "$count" "${size:-0}" "${CACHE_MAX_MB:-20}" ;;
    -h|--help) usage ;;
    "")        exit 0 ;;
    *)         fetch_art "$1" ;;
esac
