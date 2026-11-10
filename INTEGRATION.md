# Integration with Proxmox VE (upstream-shaped)

Installing this package needs three small integration
points in stock pve-manager files, applied by the
maintainer scripts (`debian/integrate.pl`, embedded
into postinst/postrm): idempotently, with
`<file>.pve-s3.bak` backups, skipped with a warning
when an anchor no longer matches, removed on
uninstall.

1. API registration — in `PVE/API2/Cluster.pm`,
   alongside the other Cluster children:

   ```perl
   use PVE::API2::Cluster::S3;
   # ...
   __PACKAGE__->register_method({
       subclass => "PVE::API2::Cluster::S3",
       path => 's3',
   });
   ```

2. UI tabs — in `PVE.dc.Config` (`pvemanagerlib.js`),
   in the Datacenter view list, after the Ceph entry,
   grouped like Permissions: one parent page plus one
   child page per section:

   ```js
   {
       xtype: 'pveS3StatusView',
       title: gettext('S3 Object Storage'),
       iconCls: 'fa fa-database',
       itemId: 's3',
       expandedOnInit: true,
   },
   {
       xtype: 'pveS3GatewaysView',
       title: gettext('Gateways'),
       iconCls: 'fa fa-server',
       groups: ['s3'],
       itemId: 's3-gateways',
   },
   // ... Tenants, Users & Keys, Buckets & Usage the same way
   ```

3. UI script — `index.html.tpl` loads
   `/pve2/js/PVES3Workspace.js` after
   `pvemanagerlib.js`, with a content-hash `ver`
   suffix so upgrades bust the browser cache.

Everything else is new files only: the API module,
the panel JS, the /usr/sbin/pve-s3-* tools, and the
HAProxy/keepalived templates under
/usr/share/pve-s3/lb.

Package Depends pull the runtime stack (radosgw,
haproxy, keepalived) onto the host. Installing the
package never creates a realm, starts a gateway, or
moves the VIP: convergence is the explicit job of
`pve-s3-bringup` / `pve-s3-lb-deploy` (or the panel),
per host.

Roles created by postinst (bundles of stock
privileges — creating them grants nothing):
S3Auditor, S3UserAdmin, S3Admin. Operators grant
them at stock ACL paths: stock PVE whitelists ACL
path roots (`PVE::AccessControl::check_path`), so
there is no `/s3` ACL tree. Grant cluster-wide at
`/` or per-tenant at `/pool/{tenant}` (tenant
operations check `/pool`), gateway operations
check `/nodes/{node}`.
