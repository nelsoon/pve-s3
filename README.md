# pve-s3-manager

S3 object storage for Proxmox VE, managed from the PVE
web UI the same way a stock feature would be: a Perl
API2 backend plus an ExtJS panel in the Datacenter
view, so the code can be handed over or submitted
upstream without a rewrite.

It puts Ceph RGW gateways on the PVE hosts of an
existing PVE-managed Ceph cluster (no cephadm), puts
a load-balanced S3 endpoint in front of them, and
manages RGW users, access keys, tenants and buckets
from the panel.

## How it fits together

- Gateways: `radosgw` on each PVE host, one daemon
  per host, systemd unit `ceph-radosgw@rgw.<host>`.
  Single realm/zonegroup/zone.
- Endpoint: HAProxy on every gateway host with a
  keepalived floating IP, TLS terminated at HAProxy,
  plain HTTP 7480 backends on the trusted host net.
- Tenancy: a tenant is a PVE resource pool mapped to
  a Ceph RGW Account (Ceph 20/21 Accounts model).
  Users created in the panel belong to exactly one
  pool; permissions are stock PVE privileges checked
  at `/pool` (per-pool at `/pool/{pool}`) and
  `/nodes/{node}` for gateway operations.
- Roles shipped by the package: `S3Auditor`
  (read-only), `S3UserAdmin`, `S3Admin`. Creating a
  role grants nothing; grant it to users/groups at
  the paths above.

## Build

```sh
make deb    # builds build/pve-s3-manager_*.deb
make lint   # perl -c on API modules, node --check on UI JS
make test   # lint + idempotence stub test + deb
```

## Install

Install the .deb on every PVE host of the cluster:

```sh
apt install ./pve-s3-manager_0.1.2-1_all.deb
```

The package pulls its runtime stack (`radosgw`,
`haproxy`, `keepalived`) via Depends, creates the
`S3Auditor`/`S3UserAdmin`/`S3Admin` roles, and
applies the three pve-manager integration points
documented in [INTEGRATION.md](INTEGRATION.md).
Installing the package never creates a realm, starts
a gateway, or moves the VIP — see
[docs/OPERATIONS.md](docs/OPERATIONS.md):

```sh
# per gateway host, then reload the panel in a browser
GATEWAY_IP=192.168.56.11 \
ZONE_ENDPOINTS="http://192.168.56.11:7480 http://192.168.56.12:7480" \
    /usr/sbin/pve-s3-bringup
LB_SRC=/usr/share/pve-s3/lb VIP=192.168.56.100 /usr/sbin/pve-s3-lb-deploy 110
/usr/sbin/pve-s3-health
```

## Use

In the web UI: Datacenter → **S3 Object Storage**
(parent page with a summary), with Gateways, Tenants,
Users & Keys and Buckets & Usage as sub-pages in the
left sidebar, like Permissions.

Clients use the endpoint with ordinary S3 tooling
(path-style, region = zonegroup name, e.g. `default`):

```sh
aws --endpoint-url https://s3.example.com --region default \
    s3 cp file s3://bucket/
```

Access keys are shown once when created; the panel
never lists secrets. Use `pve-s3-export` to back up
realm/zone/user state.

## Status

Built and validated on a three-host PVE 9.2 / Ceph
21.2 lab (gateways, endpoint, failover, host
upgrade+reboot recovery, API and panel round-trips).
This is early software; run it on a backup first
independent of the PVE VM data it shares OSDs with.

## License

GNU Affero General Public License v3; see
[LICENSE](LICENSE).
