#!/usr/bin/env bash
# btmedia-bt.sh - BlueZ RFCOMM/SDP management and diagnostics for btmedia.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
    cat <<'EOF'
usage: btmedia-bt.sh <check|advertise|cleanup|status|sudoers>
  check      Verify bluetoothd --compat, adapter power, and BlueZ tools
  advertise  Ensure Serial Port (SP) SDP record exists on configured channel
  cleanup    Kill stale rfcomm listeners and release the device node
  status     Show Bluetooth controller, active RFCOMM links, and paired devices
  sudoers    Print a minimal /etc/sudoers.d/btmedia rule for passwordless daemon use
EOF
}

check_compat() {
    local pid cmdline
    pid=$(pgrep -x bluetoothd 2>/dev/null | head -1 || true)
    if [[ -z $pid ]]; then
        log_error "bluetoothd is not running (try: sudo systemctl enable --now bluetooth)"
        return 1
    fi
    cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
    if [[ $cmdline != *--compat* && $cmdline != *-C* ]]; then
        log_error "bluetoothd is running without --compat; sdptool will fail."
        printf 'Fix: sudo systemctl edit bluetooth\n  [Service]\n  ExecStart=\n  ExecStart=/usr/lib/bluetooth/bluetoothd --compat\n' >&2
        return 1
    fi
    log_info "bluetoothd --compat OK (PID $pid)"
}

cmd_check() {
    local ok=0
    require_cmds bluetoothctl rfcomm sdptool || ok=1
    check_compat || ok=1
    if bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; then
        log_info "Bluetooth adapter powered on"
    else
        log_warn "Bluetooth adapter is powered off (daemon will attempt power on)"
    fi
    return "$ok"
}

cmd_advertise() {
    bluetoothctl power on >/dev/null 2>&1 || true
    if sudo sdptool browse local 2>/dev/null | grep -Eq "Channel: $CH( |$)"; then
        log_debug "SDP SP record already advertised on channel $CH"
        return 0
    fi
    if sudo sdptool add --channel="$CH" SP >/dev/null; then
        log_info "Advertised Serial Port profile on channel $CH"
    else
        log_error "sdptool failed — run 'btmedia-bt.sh check'"
        return 1
    fi
}

cmd_cleanup() {
    sudo pkill -f "[r]fcomm listen $DEV" 2>/dev/null || true
    sudo rfcomm release "$DEV" 2>/dev/null || true
}

cmd_status() {
    echo "=== Adapter ==="
    bluetoothctl show 2>/dev/null | grep -E 'Name:|Powered:|Discoverable:|Pairable:' || echo "Unavailable"
    echo
    echo "=== RFCOMM ($DEV) ==="
    sudo -n rfcomm show "$DEV" 2>/dev/null || echo "Not connected (or sudo ticket inactive)"
    echo
    echo "=== Paired Devices ==="
    bluetoothctl devices Paired 2>/dev/null | awk '{mac=$2; $1=$2=""; sub(/^  /, ""); printf "%s\t%s\n", mac, $0}' | column -t -s $'\t'
}

cmd_sudoers() {
    local rf sdp pk chm
    rf=$(command -v rfcomm)
    sdp=$(command -v sdptool)
    pk=$(command -v pkill)
    chm=$(command -v chmod)
    cat <<EOF
# Install with: btmedia-bt.sh sudoers | sudo tee /etc/sudoers.d/btmedia && sudo chmod 440 /etc/sudoers.d/btmedia
$USER ALL=(root) NOPASSWD: $rf, $sdp, $chm 666 $DEV, $pk -f \[r\]fcomm listen $DEV
EOF
}

case ${1:-help} in
    check)     cmd_check ;;
    advertise) cmd_advertise ;;
    cleanup)   cmd_cleanup ;;
    status)    cmd_status ;;
    sudoers)   cmd_sudoers ;;
    -h|--help|help) usage ;;
    *)         usage >&2; exit 2 ;;
esac
