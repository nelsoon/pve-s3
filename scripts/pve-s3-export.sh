#!/bin/sh
# pve-s3-export — dump RGW realm/zonegroup/zone/user state as JSON.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# R4/T2.3: these exports are the reproducible source for
# realm/zone/user state. Write them to the operator's
# secret store (mode 600, outside any git repo) — user
# exports contain secret keys.
#   pve-s3-export.sh /path/to/secret-store
set -eu

DEST=${1:?usage: pve-s3-export.sh <dest-dir>}
REALM=${REALM:-lab}
ZONEGROUP=${ZONEGROUP:-default}
ZONE=${ZONE:-default}

mkdir -p "$DEST"
umask 077

radosgw-admin realm get --rgw-realm="$REALM" > "$DEST/realm.json"
radosgw-admin zonegroup get --rgw-realm="$REALM" \
    --rgw-zonegroup="$ZONEGROUP" > "$DEST/zonegroup.json"
radosgw-admin zone get --rgw-realm="$REALM" \
    --rgw-zone="$ZONE" > "$DEST/zone.json"
radosgw-admin user list > "$DEST/users.json"
for uid in $(radosgw-admin user list 2>/dev/null \
        | tr -d '[]",' ); do
    [ -n "$uid" ] || continue
    radosgw-admin user info --uid="$uid" \
        > "$DEST/user-$uid.json"
done
chmod 600 "$DEST"/*.json
echo "exports written to $DEST (contains secret keys, keep 600)"
