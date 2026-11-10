#!/bin/sh
# pve-s3-health — one documented health check for the S3 service.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Run on any PVE host (or the workstation with ssh access).
# Checks: ceph health, every gateway unit (via ssh to
# peers), VIP presence, endpoint S3 probe, RGW pool usage.
# Exit 0 = healthy, 1 = degraded. Output is the report.
set -u

VIP=${VIP:-192.168.56.100}   # set to your endpoint VIP
ENDPOINT=${ENDPOINT:-https://$VIP}
if [ -z "${CA_BUNDLE:-}" ] && [ -f /etc/pve-s3/tls/ca.crt ]; then
    CA_BUNDLE=/etc/pve-s3/tls/ca.crt
fi
CA_BUNDLE=${CA_BUNDLE:-$HOME/.local/share/pve-s3-secrets/ca.crt}
HOSTS=${HOSTS:-cloud1 cloud2 cloud3}
FAIL=0

say() { printf '%-28s %s\n' "$1" "$2"; }
bad() { say "$1" "FAIL: $2"; FAIL=1; }

h=$(ceph health 2>/dev/null || echo UNAVAILABLE)
case "$h" in HEALTH_OK*|HEALTH_WARN*) say "ceph" "$h" ;; *) bad "ceph" "$h" ;; esac

for host in $HOSTS; do
    st=$(ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$host" \
        "systemctl is-active ceph-radosgw@rgw.$host haproxy keepalived" \
        2>/dev/null | tr '\n' ' ')
    case "$st" in
        "active active active ") say "gateway $host" "rgw+haproxy+keepalived active" ;;
        *) bad "gateway $host" "units: $st" ;;
    esac
done

holder=$(for host in $HOSTS; do
    ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$host" \
        "ip a show vmbr0 | grep -q $VIP/24 && echo $host" 2>/dev/null
done)
[ -n "$holder" ] && say "vip $VIP" "held by $holder" || bad "vip $VIP" "not held anywhere"

if [ -f "$CA_BUNDLE" ]; then CAOPT="--cacert $CA_BUNDLE"; else CAOPT="-k"; fi
if curl -fsS $CAOPT -m 10 "$ENDPOINT/" 2>/dev/null | grep -q ListAllMyBucketsResult; then
    say "endpoint $ENDPOINT" "S3 answering"
else
    bad "endpoint $ENDPOINT" "no S3 answer"
fi

users=$(radosgw-admin user list 2>/dev/null | grep -c '"' || true)
say "rgw users" "$users"
ceph df 2>/dev/null | grep rgw | while read -r line; do say "pool" "$line"; done

[ "$FAIL" = 0 ] && echo "OVERALL: OK" || echo "OVERALL: DEGRADED"
exit $FAIL
