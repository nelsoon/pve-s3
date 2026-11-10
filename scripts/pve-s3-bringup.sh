#!/bin/sh
# pve-s3-bringup — idempotent RGW bring-up/converge for ONE PVE host.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Run as root on each gateway host. Converges, in order:
#   radosgw package -> realm/zonegroup/zone -> per-host keyring
#   -> ceph.conf keyring section -> MON config -> systemd unit
#   -> local S3 probe. Re-running changes nothing when the
#   desired state already matches (T1.1 acceptance test).
#
# Desired state comes from the environment or
# /etc/pve-s3/bringup.conf (shell assignments). Example:
#   REALM=lab ZONEGROUP=default ZONE=default
#   GATEWAY_IP=192.168.56.11 RGW_PORT=7480
#   ZONE_ENDPOINTS="http://192.168.56.11:7480 http://192.168.56.12:7480"
#
# Realm/zone JSON exports (R4) are written by
# pve-s3-export.sh, not here: exports are reads, this
# script is the only writer of gateway state.
set -eu

CONF=${PVE_S3_CONF:-/etc/pve-s3/bringup.conf}
[ -f "$CONF" ] && . "$CONF"

REALM=${REALM:-lab}
ZONEGROUP=${ZONEGROUP:-default}
ZONE=${ZONE:-default}
RGW_PORT=${RGW_PORT:-7480}
HOSTNAME_SHORT=$(hostname -s)
GATEWAY_NAME=${GATEWAY_NAME:-rgw.$HOSTNAME_SHORT}
CLIENT_NAME=client.$GATEWAY_NAME
GATEWAY_IP=${GATEWAY_IP:-$(getent hosts "$HOSTNAME_SHORT" | awk '{print $1}' | head -n1)}
ZONE_ENDPOINTS=${ZONE_ENDPOINTS:-http://$GATEWAY_IP:$RGW_PORT}

CEPH_CONF=${CEPH_CONF:-/etc/ceph/ceph.conf}
KEYRING_DIR=${KEYRING_DIR:-/var/lib/ceph/radosgw/ceph-$GATEWAY_NAME}
KEYRING=$KEYRING_DIR/keyring
EXPORT_DIR=${EXPORT_DIR:-/var/lib/pve-s3}

CHANGED=0
note() { printf '%s\n' "$*"; }
changed() { CHANGED=1; note "changed: $*"; }

if [ "$(id -u)" != 0 ] && [ -z "${PVE_S3_TEST_MODE:-}" ]; then
    echo "must run as root" >&2; exit 1
fi
[ -n "$GATEWAY_IP" ] || { echo "cannot determine GATEWAY_IP" >&2; exit 1; }

# --- cluster health gate -------------------------------------------
health=$(ceph health 2>/dev/null || echo UNAVAILABLE)
case "$health" in
    HEALTH_OK*) ;;
    HEALTH_WARN*) note "warning: ceph health is '$health', proceeding" ;;
    *) echo "ceph health is '$health', refusing to proceed" >&2; exit 1 ;;
esac

# --- package ---------------------------------------------------------
if [ ! -x /usr/bin/radosgw ] && [ -z "${PVE_S3_TEST_MODE:-}" ]; then
    apt-get install -y radosgw
    changed "installed radosgw package"
fi

# --- realm / zonegroup / zone (master, single-site) ------------------
if ! radosgw-admin realm list 2>/dev/null | grep -qw "$REALM"; then
    radosgw-admin realm create --rgw-realm="$REALM" --default >/dev/null
    changed "created realm $REALM"
fi
if ! radosgw-admin zonegroup list 2>/dev/null | grep -qw "$ZONEGROUP"; then
    radosgw-admin zonegroup create --rgw-realm="$REALM" \
        --rgw-zonegroup="$ZONEGROUP" --master --default >/dev/null
    changed "created zonegroup $ZONEGROUP"
fi
endpoints_present() {
    for ep in $ZONE_ENDPOINTS; do
        radosgw-admin zonegroup get --rgw-zonegroup="$ZONEGROUP" 2>/dev/null \
            | grep -q "$ep" || return 1
    done
    return 0
}
ENDPOINTS_CSV=$(printf '%s' "$ZONE_ENDPOINTS" | tr ' ' ',')
if ! radosgw-admin zone list 2>/dev/null | grep -qw "$ZONE"; then
    radosgw-admin zone create --rgw-realm="$REALM" \
        --rgw-zonegroup="$ZONEGROUP" --rgw-zone="$ZONE" \
        --master --default --endpoints="$ENDPOINTS_CSV" >/dev/null
    changed "created zone $ZONE"
elif ! endpoints_present; then
    radosgw-admin zone modify --rgw-zonegroup="$ZONEGROUP" \
        --rgw-zone="$ZONE" --endpoints="$ENDPOINTS_CSV" >/dev/null
    changed "updated zone $ZONE endpoints"
fi
if [ "$CHANGED" = 1 ]; then
    radosgw-admin period update --commit >/dev/null
fi

# --- per-host keyring --------------------------------------------------
mkdir -p "$KEYRING_DIR"
TMPKEY=$(mktemp)
trap 'rm -f "$TMPKEY"' EXIT
ceph auth get-or-create "$CLIENT_NAME" \
    mon 'allow rw' osd 'allow rwx' mgr 'allow rw' -o "$TMPKEY"
if [ ! -f "$KEYRING" ] || ! cmp -s "$TMPKEY" "$KEYRING"; then
    install -m 600 "$TMPKEY" "$KEYRING"
    chown ceph:ceph "$KEYRING" 2>/dev/null || true
    changed "wrote keyring for $CLIENT_NAME"
fi
chown ceph:ceph "$KEYRING_DIR" 2>/dev/null || true

# --- ceph.conf keyring section (T0.2 gotcha) ---------------------------
# Stock /etc/pve/ceph.conf [client] points keyring at
# /etc/pve/priv/... which the ceph-radosgw@ unit cannot
# use. A per-gateway section overrides it. The file is
# pmxcfs-shared; the instance name keeps it host-scoped.
if ! grep -q "^\[client\.$GATEWAY_NAME\]" "$CEPH_CONF"; then
    printf '\n[client.%s]\n\tkeyring = %s\n' "$GATEWAY_NAME" "$KEYRING" \
        >> "$CEPH_CONF"
    changed "added [client.$GATEWAY_NAME] to $CEPH_CONF"
fi

# --- MON config ----------------------------------------------------------
set_cfg() {
    cur=$(ceph config get "$CLIENT_NAME" "$1" 2>/dev/null || true)
    if [ "$cur" != "$2" ]; then
        ceph config set "$CLIENT_NAME" "$1" "$2"
        changed "ceph config $CLIENT_NAME $1"
    fi
}
set_cfg rgw_frontends "beast endpoint=$GATEWAY_IP:$RGW_PORT"
set_cfg rgw_realm "$REALM"
set_cfg rgw_zonegroup "$ZONEGROUP"
set_cfg rgw_zone "$ZONE"

# --- systemd unit ----------------------------------------------------------
systemctl enable "ceph-radosgw@$GATEWAY_NAME" >/dev/null 2>&1 || true
if [ "$CHANGED" = 1 ]; then
    systemctl restart "ceph-radosgw@$GATEWAY_NAME"
elif ! systemctl is-active --quiet "ceph-radosgw@$GATEWAY_NAME"; then
    systemctl start "ceph-radosgw@$GATEWAY_NAME"
    changed "started ceph-radosgw@$GATEWAY_NAME"
fi

# --- local probe -------------------------------------------------------------
mkdir -p "$EXPORT_DIR"
i=0
while [ $i -lt 30 ]; do
    if curl -fsS "http://$GATEWAY_IP:$RGW_PORT/" 2>/dev/null \
            | grep -q 'ListAllMyBucketsResult\|Error'; then
        note "gateway $GATEWAY_NAME answering on $GATEWAY_IP:$RGW_PORT"
        note "converged (changed=$CHANGED)"
        exit 0
    fi
    i=$((i + 1)); sleep 2
done
echo "gateway did not answer S3 probe on $GATEWAY_IP:$RGW_PORT" >&2
exit 1
