# Operations

Single realm/zonegroup/zone. Zone defaults: realm
`lab`, zonegroup/zone `default`, endpoint
`s3.<domain>` (TLS at HAProxy, lab CA or ACME),
backends RGW on 7480.

## Health

    pve-s3-health

Checks Ceph health, every gateway unit
(rgw+haproxy+keepalived), the VIP holder, the
endpoint S3 probe, and RGW pool usage. Exit 1 and
reports DEGRADED when anything is down; the
endpoint may still answer — that is the point of
multiple gateways.

## Gateways and endpoint

    GATEWAY_IP=192.168.56.11 \
    ZONE_ENDPOINTS="http://192.168.56.11:7480 http://192.168.56.12:7480" \
        pve-s3-bringup          # idempotent converge, per host
    LB_SRC=/usr/share/pve-s3/lb VIP=<endpoint-vip> pve-s3-lb-deploy <priority>
    pve-s3-health

Priorities: highest wins the VIP (e.g. 110/100/90).
Stopping HAProxy on the VIP holder moves it.

## Users, keys, buckets

Prefer the panel (Datacenter → S3 Object Storage,
Tenants/Users/Buckets pages). CLI equivalents are in
the bring-up source; rules that are easy to get
wrong:

- Client region must be the zonegroup name
  (`default`), or bucket creation fails.
- Secret keys appear once at creation. `radosgw-admin`
  user records contain secrets — redirect them to a
  600 file instead of printing them.
- Key rotation: create the new key, update clients,
  then revoke the old key (panel Rotate does this).

## Config backup

    pve-s3-export /path/to/secret-store   # 600 JSON, contains keys

Run after any user/zone change. There is no timer
yet; a systemd timer is pending panel work.

## Tenancy and permissions

Tenant = PVE resource pool = RGW Account. Grant
roles at stock paths: cluster-wide at `/`, per-tenant
at `/pool/{pool}`; gateway restart checks
`Sys.Modify` on `/nodes/{node}`. Roles: `S3Auditor`,
`S3UserAdmin`, `S3Admin`. A grant only at
`/pool/{pool}` does not satisfy the static `/pool`
check; operators also need a pool-level role.
