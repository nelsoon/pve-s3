#!/bin/sh
# Offline stub test for pve-s3-bringup.sh: fakes ceph,
# radosgw-admin, systemctl and curl on PATH, runs the
# bring-up twice, and asserts the second run converges
# with changed=0 and no mutating stub calls beyond reads.
# The real T1.1 test (run twice on the lab) still applies.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN=$TMP/bin; STATE=$TMP/state
mkdir -p "$BIN" "$STATE" "$TMP/ceph" "$TMP/keys" "$TMP/out"
export STUB_STATE=$STATE
: > "$STATE/calls.log"

cat > "$BIN/ceph" <<'EOF'
#!/bin/sh
echo "ceph $*" >> "$STUB_STATE/calls.log"
case "$1 $2" in
  "health ") echo HEALTH_OK ;;
  "auth get-or-create")
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out=$a; prev=$a; done
    printf '[%s]\nkey = fake\n' "$3" > "$out" ;;
  "config get") [ -f "$STUB_STATE/cfg-$3-$4" ] && cat "$STUB_STATE/cfg-$3-$4" ;;
  "config set") printf '%s' "$5" > "$STUB_STATE/cfg-$3-$4" ;;
esac
EOF

cat > "$BIN/radosgw-admin" <<'EOF'
#!/bin/sh
echo "radosgw-admin $*" >> "$STUB_STATE/calls.log"
case "$1 $2" in
  "realm list") [ -f "$STUB_STATE/realm" ] && echo '["lab"]' || echo '[]' ;;
  "realm create") touch "$STUB_STATE/realm"; echo '{}' ;;
  "zonegroup list") [ -f "$STUB_STATE/zg" ] && echo '["default"]' || echo '[]' ;;
  "zonegroup create") touch "$STUB_STATE/zg"; echo '{}' ;;
  "zone list") [ -f "$STUB_STATE/zone" ] && echo '["default"]' || echo '[]' ;;
  "zone create") touch "$STUB_STATE/zone"; echo '{}' ;;
  "zone get") echo '{}' ;;
  "zonegroup get") echo '{"zones":[{"endpoints":["http://10.0.2.51:7480"]}]}' ;;
  "period update") echo '{}' ;;
esac
EOF

cat > "$BIN/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$STUB_STATE/calls.log"
case "$1" in
  is-active) [ -f "$STUB_STATE/active" ] ;;
  start|restart) touch "$STUB_STATE/active" ;;
esac
EOF

cat > "$BIN/curl" <<'EOF'
#!/bin/sh
echo '<ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"></ListAllMyBucketsResult>'
EOF
chmod +x "$BIN"/*

run_bringup() {
  PATH="$BIN:/usr/bin:/bin" PVE_S3_TEST_MODE=1 \
  CEPH_CONF="$TMP/ceph/ceph.conf" \
  KEYRING_DIR="$TMP/keys/ceph-rgw.$(hostname -s)" \
  EXPORT_DIR="$TMP/out" \
  GATEWAY_IP=10.0.2.51 GATEWAY_NAME="rgw.$(hostname -s)" \
  ZONE_ENDPOINTS="http://10.0.2.51:7480" \
  sh "$ROOT/scripts/pve-s3-bringup.sh"
}
: > "$TMP/ceph/ceph.conf"

run_bringup > "$TMP/run1.log" 2>&1
grep -q 'changed=1' "$TMP/run1.log" || { cat "$TMP/run1.log"; echo "FAIL: run1 should change state"; exit 1; }
cp "$STATE/calls.log" "$TMP/calls1.log"; : > "$STATE/calls.log"

run_bringup > "$TMP/run2.log" 2>&1
grep -q 'changed=0' "$TMP/run2.log" || { cat "$TMP/run2.log"; echo "FAIL: run2 should converge (changed=0)"; exit 1; }
if grep -Eq 'realm create|zonegroup create|zone create|zone modify|config set|systemctl (start|restart)' "$STATE/calls.log"; then
    cat "$STATE/calls.log"; echo "FAIL: run2 issued mutating calls"; exit 1
fi
grep -q '\[client\.rgw\.' "$TMP/ceph/ceph.conf" || { echo "FAIL: ceph.conf section missing"; exit 1; }
echo "PASS: bring-up converges on second run (stubbed)"
