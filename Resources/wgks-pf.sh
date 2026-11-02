#!/bin/bash
# pf rules for the WireGuard kill switch. Run as root by the app.
#
#   wgks-pf.sh on <utunN> <port> <server_ip>...   load (or reload) the rules
#   wgks-pf.sh off                                remove the rules
#
# The rules live in their own anchor: neither the main ruleset nor other
# tools' rules are touched, and pf is enabled by reference (pfctl -E / -X)
# instead of pfctl -e / -d.

set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# /etc/pf.conf already evaluates "com.apple/*": a sub-anchor there is picked up
# without editing the file. The 000 prefix puts it before Apple's anchors.
ANCHOR="com.apple/000.wgks"
# /var/run is cleared at boot, like pf rules: the token stays consistent.
TOKEN_FILE=/var/run/wgks.token

die() { echo "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "This script must run as root."

rules() {
    local iface=$1 port=$2
    shift 2
    cat <<EOF
# "flags any" keeps connections already open locally and in the tunnel
# alive when the state table is flushed.
pass quick on lo0 all flags any keep state
pass quick on $iface all flags any keep state
# DHCP and IPv6 neighbor discovery, without which Wi-Fi/Ethernet cannot configure itself
pass out quick inet proto udp from any port 68 to any port 67
pass in quick inet proto udp from any port 67 to any port 68
pass quick inet6 proto icmp6 all icmp6-type { neighbrsol, neighbradv, routersol, routeradv }
# Only the WireGuard server is reachable outside the tunnel
pass out quick proto udp to { $* } port $port
# Everything else: rejected immediately on the way out (the app relies on this to check), dropped on the way in
block return out quick all
block drop in quick all
EOF
}

case "${1:-}" in
on)
    [[ $# -ge 4 ]] || die "Usage: $0 on <utunN> <port> <server_ip>..."
    iface=$2 port=$3
    shift 3
    [[ $iface =~ ^utun[0-9]+$ ]] || die "Invalid interface: $iface"
    [[ $port =~ ^[0-9]{1,5}$ ]] && (( port >= 1 && port <= 65535 )) || die "Invalid port: $port"
    for ip in "$@"; do
        [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] || die "Invalid IP address: $ip"
    done

    # If the main ruleset is not loaded, our anchor would never be evaluated
    if ! pfctl -s rules 2>/dev/null | grep -q 'com.apple/\*'; then
        pfctl -q -f /etc/pf.conf
    fi

    rules "$iface" "$port" "$@" | pfctl -q -a "$ANCHOR" -f -

    if [[ ! -s $TOKEN_FILE ]]; then
        token=$(pfctl -E 2>&1 | awk '/^Token/ { print $NF }')
        [[ -n $token ]] || die "Could not enable pf."
        echo "$token" > "$TOKEN_FILE"
    fi

    # Connections already established outside the tunnel have a pf state that
    # would bypass the new rules: cut them.
    pfctl -q -F states
    ;;
off)
    pfctl -q -a "$ANCHOR" -F rules || true
    if [[ -s $TOKEN_FILE ]]; then
        pfctl -q -X "$(cat "$TOKEN_FILE")" || true
        rm -f "$TOKEN_FILE"
    fi
    ;;
*)
    die "Usage: $0 on <utunN> <port> <server_ip>... | off"
    ;;
esac
