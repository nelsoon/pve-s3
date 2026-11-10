# Copyright (C) 2026 pve-s3 contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::API2::Cluster::S3;

use strict;
use warnings;

use JSON::PP ();
use IO::Socket::INET ();
use Socket qw(inet_aton AF_INET);
use Digest::SHA qw(sha256_hex hmac_sha256);
use Sys::Hostname ();

use PVE::Tools qw(run_command);
use PVE::RPCEnvironment;

use base qw(PVE::RESTHandler);

# S3 object storage on the PVE Ceph cluster (Ceph RGW).
# All operations go through radosgw-admin on the host
# serving the request; the panel and any other client
# use only this API. Secret keys are returned exactly
# once, by the create calls, and never listed.
#
# Permission paths: stock PVE whitelists ACL path roots
# (PVE::AccessControl::check_path), so there is no
# /s3 tree. S3 checks hang under existing roots:
# cluster reads at '/', tenant (user/bucket) operations
# at '/pool' (grant per-tenant at '/pool/{tenant}'),
# gateway operations at '/nodes/{node}'. Privilege
# names are the stock ones; the package's roles
# (S3Auditor/S3UserAdmin/S3Admin) bundle them.

my sub run_json {
    my ($cmd) = @_;
    my $out = '';
    run_command($cmd, outfunc => sub { $out .= shift });
    return JSON::PP->new->decode($out) if length $out;
    return undef;
}

my sub run_ok {
    my ($cmd) = @_;
    run_command($cmd, outfunc => sub {});
    return 1;
}

# Tenancy (0.1.1): a tenant is a PVE resource pool.
# Static checks gate the /pool tree; whenever a call
# names a tenant, the same privilege is also required
# on /pool/{tenant} itself, so a grant scoped to one
# pool cannot act on another tenant.
my sub tenant_priv_check {
    my ($tenant, $privs) = @_;
    return if !$tenant;
    my $rpcenv = PVE::RPCEnvironment::get();
    my $authuser = $rpcenv->get_user();
    die "permission denied on /pool/$tenant ("
        . join(',', $privs->@*) . ")\n"
        if !$rpcenv->check($authuser, "/pool/$tenant", $privs, 1);
}

my sub pve_pools {
    my $cfg = '';
    if (open my $fh, '<', '/etc/pve/user.cfg') {
        local $/;
        $cfg = <$fh> // '';
        close $fh;
    }
    my $pools = {};
    for my $line (split /\n/, $cfg) {
        if ($line =~ /^pool:\s*(\S+)\s*:\s*(.*)$/) {
            $pools->{$1} = $2 // '';
        }
    }
    return $pools;
}

my sub rgw_users {
    my $list = run_json(['radosgw-admin', 'user', 'list']) // [];
    my $res = [];
    for my $uid (sort $list->@*) {
        my $info = eval {
            run_json(['radosgw-admin', 'user', 'info',
                '--uid', $uid]) } // {};
        my $stats = eval {
            run_json(['radosgw-admin', 'user', 'stats',
                '--uid', $uid]) } // {};
        my $owned = eval {
            run_json(['radosgw-admin', 'bucket', 'list',
                '--uid', $uid]) } // [];
        my $st = $stats->{stats} // {};
        push $res->@*, {
            uid => $uid,
            tenant => $info->{tenant} // '',
            'display-name' => $info->{'display_name'} // '',
            suspended => $info->{suspended} ? 1 : 0,
            buckets => scalar $owned->@*,
            objects => $st->{num_objects} // 0,
            used => $st->{size_actual} // 0,
            quota => $info->{user_quota}->{max_size} // -1,
            keys => scalar($info->{keys}->@*),
        };
    }
    return $res;
}

my sub xml_unescape {
    my ($v) = @_;
    $v =~ s/&lt;/</g; $v =~ s/&gt;/>/g; $v =~ s/&quot;/"/g;
    $v =~ s/&apos;/'/g; $v =~ s/&amp;/&/g;
    return $v;
}

my sub uri_escape_path {
    my ($path) = @_;
    $path =~ s/([^A-Za-z0-9._~\/-])/sprintf("%%%02X", ord($1))/ge;
    return $path;
}

# Query values are fully encoded (including '/'),
# as SigV4 canonicalization requires.
my sub uri_escape_query {
    my ($value) = @_;
    $value =~ s/([^A-Za-z0-9._~-])/sprintf("%%%02X", ord($1))/ge;
    return $value;
}

# Signed S3 request on behalf of the bucket owner
# (keys read server-side via user info, never returned).
# Args: uid, tenant, method, path (starting with /),
# query (without ?, may be ''), body. Returns (status, body).
my sub s3_signed_request {
    my ($uid, $tenant, $method, $path, $query, $body) = @_;
    $body //= '';
    my $ucmd = ['radosgw-admin', 'user', 'info', '--uid', $uid];
    push $ucmd->@*, '--tenant', $tenant if $tenant;
    my $info = run_json($ucmd) or die "no such user: $uid\n";
    my $key = $info->{keys}[0] or die "user $uid has no keys\n";

    my $zg = run_json(['radosgw-admin', 'zonegroup', 'get']) // {};
    my $ep = $zg->{zones}[0]{endpoints}[0]
        or die "no gateway endpoint configured\n";
    my ($host, $port) = $ep =~ m{://([^:/]+)(?::(\d+))?};
    $port //= 7480;

    my @t = gmtime();
    my $amzdate = sprintf("%04d%02d%02dT%02d%02d%02dZ",
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    my $date = substr($amzdate, 0, 8);
    my $region = 'default';
    my $payload = sha256_hex($body);
    # SigV4 canonical query: parameters sorted by name,
    # bare subresources (versioning, lifecycle) get '='.
    my @pairs = map {
        my ($n, $v) = split /=/, $_, 2;
        [$n, $v // ''];
    } split /&/, $query;
    my $canon_query = join('&',
        map { "$_->[0]=$_->[1]" }
        sort { $a->[0] cmp $b->[0] } @pairs);
    $canon_query = '' if $query eq '';
    my $canon = join("\n",
        $method, $path, $canon_query,
        "host:$host:$port\nx-amz-content-sha256:$payload\n"
            . "x-amz-date:$amzdate\n",
        'host;x-amz-content-sha256;x-amz-date', $payload);
    my $scope = "$date/$region/s3/aws4_request";
    my $to_sign = join("\n", 'AWS4-HMAC-SHA256', $amzdate,
        $scope, sha256_hex($canon));
    my $k = hmac_sha256('aws4_request',
        hmac_sha256('s3',
        hmac_sha256($region,
        hmac_sha256($date, 'AWS4' . $key->{secret_key}))));
    my $sig = unpack('H*', hmac_sha256($to_sign, $k));

    my $sock = IO::Socket::INET->new(
        PeerHost => $host, PeerPort => $port, Timeout => 10)
        or die "cannot reach gateway $host:$port\n";
    my $target = $path . ($query ? "?$canon_query" : '');
    print $sock "$method $target HTTP/1.1\r\n"
        . "Host: $host:$port\r\n"
        . "Connection: close\r\n"
        . "x-amz-content-sha256: $payload\r\n"
        . "x-amz-date: $amzdate\r\n"
        . "Authorization: AWS4-HMAC-SHA256 "
        . "Credential=$key->{access_key}/$scope, "
        . "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
        . "Signature=$sig\r\n"
        . "Content-Length: " . length($body) . "\r\n\r\n" . $body;
    my $response = do { local $/; <$sock> } // '';
    close $sock;
    my ($status) = $response =~ m{HTTP/1\.1 (\d+)};
    my ($rbody) = $response =~ /\r\n\r\n(.*)$/s;
    return ($status // 0, $rbody // '');
}

# The owner of a bucket as (uid, tenant): RGW reports
# owner as "uid" or "tenant$uid".
my sub bucket_owner {
    my ($bucket) = @_;
    my $stats = run_json(['radosgw-admin', 'bucket', 'stats',
        '--bucket', $bucket]) // {};
    my $owner = $stats->{owner} // '';
    die "bucket not found: $bucket\n" if !$owner;
    return ($2, $1) if $owner =~ /^(.*)\$(.+)$/;
    return ($owner, '');
}

# Ceph 21 radosgw-admin cannot create buckets; create
# through the S3 API signed with the owner's own keys
# (read server-side via user info, never returned).
my sub s3_create_bucket {
    my ($uid, $tenant, $bucket) = @_;
    my ($status, $body) = s3_signed_request(
        $uid, $tenant, 'PUT', "/$bucket", '', '');
    die "bucket create failed ($status): $body\n"
        if $status != 200;
    return 1;
}

# Public endpoint name, as configured by the operator
# (single line in /etc/pve-s3/endpoint, e.g.
# https://s3.example.com). Empty when unconfigured.
my sub endpoint_name {
    my $name = '';
    if (open my $fh, '<', '/etc/pve-s3/endpoint') {
        local $/;
        $name = <$fh> // '';
        close $fh;
        $name =~ s/\s+//g;
    }
    return $name;
}

my sub strip_keys {
    my ($info) = @_;
    return [ map { {
        'access-key' => $_->{access_key},
        'secret-key' => $_->{secret_key},
        user => $_->{user},
    } } $info->{keys}->@* ];
}

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "S3 service sections.",
    permissions => {
        check => ['perm', '/', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
        links => [{ rel => 'child', href => "{name}" }],
    },
    code => sub {
        return [
            { name => 'status' },
            { name => 'gateways' },
            { name => 'tenants' },
            { name => 'users' },
            { name => 'buckets' },
        ];
    }});

__PACKAGE__->register_method({
    name => 'status',
    path => 'status',
    method => 'GET',
    protected => 1,
    description => "S3 service status summary.",
    permissions => {
        check => ['perm', '/', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => { type => 'object' },
    code => sub {
        my $health = '';
        run_command(['ceph', 'health'],
            outfunc => sub { $health .= shift });
        chomp $health;
        my $realm = eval {
            run_json(['radosgw-admin', 'realm', 'list']) } // {};
        my $users = eval { rgw_users() } // [];
        my $buckets = eval {
            run_json(['radosgw-admin', 'bucket', 'list']) } // [];
        return {
            health => $health,
            realm => ($realm->{realms} // [])->[0] // '',
            endpoint => endpoint_name(),
            users => scalar $users->@*,
            buckets => scalar $buckets->@*,
        };
    }});

__PACKAGE__->register_method({
    name => 'gateways',
    path => 'gateways',
    method => 'GET',
    protected => 1,
    description => "List RGW gateways from the zone endpoints.",
    permissions => {
        check => ['perm', '/', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my $zg = run_json(['radosgw-admin', 'zonegroup', 'get']) // {};
        my $me = Sys::Hostname::hostname();
        my $res = [];
        for my $zone (($zg->{zones} // [])->@*) {
            for my $ep (($zone->{endpoints} // [])->@*) {
                my ($host) = $ep =~ m{://([^:/]+)};
                my $status = 'down';
                my $sock = IO::Socket::INET->new(
                    PeerHost => $host, PeerPort => 7480, Timeout => 2);
                if ($sock) {
                    print $sock "GET / HTTP/1.0\r\nHost: $host\r\n\r\n";
                    my $line = <$sock> // '';
                    $status = 'up' if $line =~ /200/;
                    close $sock;
                }
                my $name = $host;
                if (my $packed = inet_aton($host)) {
                    my $fqdn = gethostbyaddr($packed, AF_INET);
                    $name = $fqdn =~ s/\..*//r if $fqdn;
                }
                my $unit = '';
                if ($name eq $me || $host eq $me) {
                    run_command(['systemctl', 'is-active',
                        "ceph-radosgw\@rgw.$me"],
                        outfunc => sub { $unit .= shift });
                    chomp $unit;
                }
                push $res->@*, {
                    gateway => "rgw.$name",
                    host => $host,
                    endpoint => $ep,
                    zone => $zone->{name},
                    status => $status,
                    unit => $unit,
                };
            }
        }
        return $res;
    }});

__PACKAGE__->register_method({
    name => 'gateway_restart',
    path => 'gateways/restart',
    method => 'POST',
    protected => 1,
    description => "Restart the RGW gateway on this host.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => {
                type => 'string',
                description => "Gateway host (must be this host).",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $me = Sys::Hostname::hostname();
        die "restart must run on $param->{node} (this host is $me)\n"
            if $param->{node} ne $me;
        run_ok(['systemctl', 'restart', "ceph-radosgw\@rgw.$me"]);
        return "ceph-radosgw\@rgw.$me restarted on $me";
    }});

__PACKAGE__->register_method({
    name => 'tenants',
    path => 'tenants',
    method => 'GET',
    protected => 1,
    description => "List tenants (PVE pools mapped to RGW).",
    permissions => {
        check => ['perm', '/pool', ['Pool.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my $pools = pve_pools();
        my $users = rgw_users();
        my $res = [];
        for my $pool (sort keys $pools->%*) {
            my $mine = [ grep { $_->{tenant} eq $pool } $users->@* ];
            my ($objects, $used) = (0, 0);
            $objects += $_->{objects} for $mine->@*;
            $used += $_->{used} for $mine->@*;
            push $res->@*, {
                tenant => $pool,
                pool => $pool,
                users => scalar $mine->@*,
                objects => $objects,
                used => $used,
            };
        }
        return $res;
    }});

__PACKAGE__->register_method({
    name => 'tenant_create',
    path => 'tenants',
    method => 'POST',
    protected => 1,
    description => "Create a tenant: PVE pool + RGW account.",
    permissions => {
        check => ['perm', '/pool', ['Pool.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            tenant => {
                type => 'string',
                pattern => '^[A-Za-z0-9][A-Za-z0-9._-]*$',
                description => "Tenant name (= PVE pool ID).",
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $tenant = $param->{tenant};
        my $pools = pve_pools();
        if (!$pools->{$tenant}) {
            run_ok(['pveum', 'pool', 'add', $tenant,
                '--comment', 'pve-s3 tenant']);
        }
        my $account = eval {
            run_json(['radosgw-admin', 'account', 'create',
                '--account-name', $tenant]) };
        return {
            tenant => $tenant,
            pool => $tenant,
            'account-id' => $account->{id} // '',
        };
    }});

__PACKAGE__->register_method({
    name => 'users',
    path => 'users',
    method => 'GET',
    protected => 1,
    description => "List S3 users (no secret keys).",
    permissions => {
        check => ['perm', '/pool', ['Datastore.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        return rgw_users();
    }});

__PACKAGE__->register_method({
    name => 'user_create',
    path => 'users',
    method => 'POST',
    protected => 1,
    description => "Create an S3 user. Returns its key once.",
    permissions => {
        check => ['perm', '/pool', ['User.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            uid => {
                type => 'string',
                pattern => '^[A-Za-z0-9][A-Za-z0-9._-]*$',
                description => "The S3 user ID.",
            },
            'display-name' => {
                type => 'string',
                optional => 1,
                description => "Display name.",
            },
            tenant => {
                type => 'string',
                optional => 1,
                pattern => '^[A-Za-z0-9_]*$',
                description => "RGW tenant (panel: PVE pool mapping).",
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        tenant_priv_check($param->{tenant}, ['User.Modify']);
        my $cmd = ['radosgw-admin', 'user', 'create',
            '--uid', $param->{uid},
            '--display-name', $param->{'display-name'} // $param->{uid}];
        push $cmd->@*, '--tenant', $param->{tenant}
            if $param->{tenant};
        my $info = run_json($cmd);
        return {
            uid => $param->{uid},
            tenant => $param->{tenant} // '',
            keys => strip_keys($info),
        };
    }});

__PACKAGE__->register_method({
    name => 'user_delete',
    path => 'users/{uid}',
    method => 'DELETE',
    protected => 1,
    description => "Delete an S3 user.",
    permissions => {
        check => ['perm', '/pool', ['User.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            uid => { type => 'string' },
            tenant => { type => 'string', optional => 1 },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        tenant_priv_check($param->{tenant}, ['User.Modify']);
        my $cmd = ['radosgw-admin', 'user', 'rm',
            '--uid', $param->{uid}];
        push $cmd->@*, '--tenant', $param->{tenant}
            if $param->{tenant};
        run_ok($cmd);
        return "user $param->{uid} deleted";
    }});

__PACKAGE__->register_method({
    name => 'key_create',
    path => 'users/{uid}/keys',
    method => 'POST',
    protected => 1,
    description => "Create a key for a user. Returned once.",
    permissions => {
        check => ['perm', '/pool', ['Datastore.AllocateSpace']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            uid => { type => 'string' },
            tenant => { type => 'string', optional => 1 },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        tenant_priv_check($param->{tenant},
            ['Datastore.AllocateSpace']);
        my $cmd = ['radosgw-admin', 'key', 'create',
            '--uid', $param->{uid}, '--key-type', 's3',
            '--gen-access-key', '--gen-secret'];
        push $cmd->@*, '--tenant', $param->{tenant}
            if $param->{tenant};
        my $info = run_json($cmd);
        my $keys = strip_keys($info);
        return $keys->[-1];
    }});

__PACKAGE__->register_method({
    name => 'key_delete',
    path => 'users/{uid}/keys/{access-key}',
    method => 'DELETE',
    protected => 1,
    description => "Revoke a user's access key.",
    permissions => {
        check => ['perm', '/pool', ['User.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            uid => { type => 'string' },
            'access-key' => { type => 'string' },
            tenant => { type => 'string', optional => 1 },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        tenant_priv_check($param->{tenant}, ['User.Modify']);
        my $cmd = ['radosgw-admin', 'key', 'rm',
            '--uid', $param->{uid},
            '--access-key', $param->{'access-key'}];
        push $cmd->@*, '--tenant', $param->{tenant}
            if $param->{tenant};
        run_ok($cmd);
        return "key revoked for $param->{uid}";
    }});

__PACKAGE__->register_method({
    name => 'keys_list',
    path => 'users/{uid}/keys',
    method => 'GET',
    protected => 1,
    description => "List a user's access keys (never secrets).",
    permissions => {
        check => ['perm', '/pool', ['Datastore.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            uid => { type => 'string' },
            tenant => { type => 'string', optional => 1 },
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;
        tenant_priv_check($param->{tenant}, ['Datastore.Audit']);
        my $cmd = ['radosgw-admin', 'user', 'info',
            '--uid', $param->{uid}];
        push $cmd->@*, '--tenant', $param->{tenant}
            if $param->{tenant};
        my $info = run_json($cmd) // {};
        return [ map { {
            'access-key' => $_->{access_key},
            created => $_->{create_date} // '',
            active => $_->{active} ? 1 : 0,
        } } ($info->{keys} // [])->@* ];
    }});

__PACKAGE__->register_method({
    name => 'user_suspend',
    path => 'users/{uid}/suspend',
    method => 'POST',
    protected => 1,
    description => "Suspend (1) or re-enable (0) an S3 user.",
    permissions => {
        check => ['perm', '/pool', ['User.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            uid => { type => 'string' },
            tenant => { type => 'string', optional => 1 },
            suspend => {
                type => 'boolean',
                description => "1 suspends, 0 re-enables.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        tenant_priv_check($param->{tenant}, ['User.Modify']);
        my $cmd = ['radosgw-admin', 'user',
            $param->{suspend} ? 'suspend' : 'enable',
            '--uid', $param->{uid}];
        push $cmd->@*, '--tenant', $param->{tenant}
            if $param->{tenant};
        run_ok($cmd);
        return $param->{suspend}
            ? "user $param->{uid} suspended"
            : "user $param->{uid} enabled";
    }});

__PACKAGE__->register_method({
    name => 'buckets',
    path => 'buckets',
    method => 'GET',
    protected => 1,
    description => "List buckets with usage.",
    permissions => {
        check => ['perm', '/pool', ['Datastore.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my $list = run_json(['radosgw-admin', 'bucket', 'list']) // [];
        my $res = [];
        for my $bucket (sort $list->@*) {
            my $stats = eval {
                run_json(['radosgw-admin', 'bucket', 'stats',
                    '--bucket', $bucket]) } // {};
            my $usage = $stats->{usage}->{'rgw.main'} // {};
            push $res->@*, {
                bucket => $bucket,
                owner => $stats->{owner} // '',
                tenant => $stats->{tenant} // '',
                objects => $usage->{num_objects} // 0,
                used => $usage->{size_actual} // 0,
            };
        }
        return $res;
    }});

__PACKAGE__->register_method({
    name => 'bucket_create',
    path => 'buckets',
    method => 'POST',
    protected => 1,
    description => "Create a bucket for a user.",
    permissions => {
        check => ['perm', '/pool', ['Datastore.AllocateSpace']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            bucket => {
                type => 'string',
                pattern => '^[a-z0-9][a-z0-9.-]*$',
                description => "Bucket name.",
            },
            uid => {
                type => 'string',
                description => "Owning S3 user ID.",
            },
            tenant => { type => 'string', optional => 1 },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        tenant_priv_check($param->{tenant},
            ['Datastore.AllocateSpace']);
        s3_create_bucket($param->{uid}, $param->{tenant},
            $param->{bucket});
        return "bucket $param->{bucket} created";
    }});

__PACKAGE__->register_method({
    name => 'objects_list',
    path => 'buckets/{bucket}/objects',
    method => 'GET',
    protected => 1,
    description => "List objects in a bucket (ListObjectsV2).",
    permissions => {
        check => ['perm', '/pool', ['Datastore.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            bucket => { type => 'string' },
            prefix => { type => 'string', optional => 1 },
            delimiter => { type => 'string', optional => 1 },
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;
        my ($uid, $tenant) = bucket_owner($param->{bucket});
        tenant_priv_check($tenant, ['Datastore.Audit']);
        my $query = 'list-type=2&max-keys=200';
        $query .= '&prefix=' . uri_escape_query($param->{prefix})
            if $param->{prefix};
        $query .= '&delimiter=' . uri_escape_query($param->{delimiter})
            if $param->{delimiter};
        my ($status, $xml) = s3_signed_request($uid, $tenant,
            'GET', "/$param->{bucket}", $query, '');
        die "list objects failed ($status): $xml\n" if $status != 200;
        my $res = [];
        while ($xml =~ m{<CommonPrefixes><Prefix>([^<]*)</Prefix>}g) {
            push $res->@*, {
                key => xml_unescape($1), type => 'prefix',
                size => 0, modified => '', storage => '',
            };
        }
        while ($xml =~ m{<Contents>(.*?)</Contents>}gs) {
            my $c = $1;
            my ($k) = $c =~ m{<Key>([^<]*)</Key>};
            my ($sz) = $c =~ m{<Size>(\d+)</Size>};
            my ($lm) = $c =~ m{<LastModified>([^<]*)</LastModified>};
            my ($sc) = $c =~ m{<StorageClass>([^<]*)</StorageClass>};
            push $res->@*, {
                key => xml_unescape($k // ''), type => 'object',
                size => $sz // 0, modified => $lm // '',
                storage => $sc // '',
            };
        }
        return [ sort { $a->{key} cmp $b->{key} } $res->@* ];
    }});

__PACKAGE__->register_method({
    name => 'object_delete',
    path => 'buckets/{bucket}/objects',
    method => 'DELETE',
    protected => 1,
    description => "Delete one object from a bucket.",
    permissions => {
        check => ['perm', '/pool', ['Datastore.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            bucket => { type => 'string' },
            key => { type => 'string' },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my ($uid, $tenant) = bucket_owner($param->{bucket});
        tenant_priv_check($tenant, ['Datastore.Allocate']);
        my $path = "/$param->{bucket}/" . uri_escape_path($param->{key});
        my ($status, $body) = s3_signed_request($uid, $tenant,
            'DELETE', $path, '', '');
        die "delete object failed ($status): $body\n"
            if $status != 204 && $status != 200;
        return "object $param->{key} deleted";
    }});

__PACKAGE__->register_method({
    name => 'bucket_settings',
    path => 'buckets/{bucket}/settings',
    method => 'GET',
    protected => 1,
    description => "Bucket versioning and lifecycle settings.",
    permissions => {
        check => ['perm', '/pool', ['Datastore.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            bucket => { type => 'string' },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my ($uid, $tenant) = bucket_owner($param->{bucket});
        tenant_priv_check($tenant, ['Datastore.Audit']);
        my ($vs, $vxml) = s3_signed_request($uid, $tenant,
            'GET', "/$param->{bucket}", 'versioning', '');
        my ($versioning) = $vxml =~ m{<Status>([^<]*)</Status>};
        my ($ls, $lxml) = s3_signed_request($uid, $tenant,
            'GET', "/$param->{bucket}", 'lifecycle', '');
        my %lc;
        if ($ls == 200) {
            ($lc{'expiration-days'}) =
                $lxml =~ m{<Expiration><Days>(\d+)</Days>};
            ($lc{'noncurrent-days'}) = $lxml =~
                m{<NoncurrentVersionExpiration><NoncurrentDays>(\d+)};
            ($lc{'abort-days'}) = $lxml =~
                m{<AbortIncompleteMultipartUpload><DaysAfterInitiation>(\d+)};
        }
        return {
            bucket => $param->{bucket},
            owner => $tenant ? "$tenant\$$uid" : $uid,
            versioning => $versioning // '',
            'expiration-days' => $lc{'expiration-days'} // 0,
            'noncurrent-days' => $lc{'noncurrent-days'} // 0,
            'abort-days' => $lc{'abort-days'} // 0,
        };
    }});

__PACKAGE__->register_method({
    name => 'bucket_versioning',
    path => 'buckets/{bucket}/versioning',
    method => 'POST',
    protected => 1,
    description => "Enable or suspend bucket versioning.",
    permissions => {
        check => ['perm', '/pool', ['Datastore.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            bucket => { type => 'string' },
            status => {
                type => 'string',
                enum => ['Enabled', 'Suspended'],
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my ($uid, $tenant) = bucket_owner($param->{bucket});
        tenant_priv_check($tenant, ['Datastore.Allocate']);
        my $body = '<VersioningConfiguration '
            . 'xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            . "<Status>$param->{status}</Status>"
            . '</VersioningConfiguration>';
        my ($status, $rbody) = s3_signed_request($uid, $tenant,
            'PUT', "/$param->{bucket}", 'versioning', $body);
        die "versioning update failed ($status): $rbody\n"
            if $status != 200;
        return "versioning $param->{status} on $param->{bucket}";
    }});

__PACKAGE__->register_method({
    name => 'bucket_lifecycle',
    path => 'buckets/{bucket}/lifecycle',
    method => 'POST',
    protected => 1,
    description => "Set (or clear, all-zero) the panel lifecycle rule.",
    permissions => {
        check => ['perm', '/pool', ['Datastore.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            bucket => { type => 'string' },
            'expiration-days' => { type => 'integer', optional => 1 },
            'noncurrent-days' => { type => 'integer', optional => 1 },
            'abort-days' => { type => 'integer', optional => 1 },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my ($uid, $tenant) = bucket_owner($param->{bucket});
        tenant_priv_check($tenant, ['Datastore.Allocate']);
        my ($exp, $noncur, $abort) = (
            $param->{'expiration-days'} // 0,
            $param->{'noncurrent-days'} // 0,
            $param->{'abort-days'} // 0);
        if (!$exp && !$noncur && !$abort) {
            my ($status, $rbody) = s3_signed_request($uid, $tenant,
                'DELETE', "/$param->{bucket}", 'lifecycle', '');
            die "lifecycle delete failed ($status): $rbody\n"
                if $status != 204 && $status != 200;
            return "lifecycle cleared on $param->{bucket}";
        }
        my $rule = '<Rule><ID>pve-panel-rule</ID>'
            . '<Status>Enabled</Status><Filter></Filter>';
        $rule .= "<Expiration><Days>$exp</Days></Expiration>" if $exp;
        $rule .= '<NoncurrentVersionExpiration>'
            . "<NoncurrentDays>$noncur</NoncurrentDays>"
            . '</NoncurrentVersionExpiration>' if $noncur;
        $rule .= '<AbortIncompleteMultipartUpload>'
            . "<DaysAfterInitiation>$abort</DaysAfterInitiation>"
            . '</AbortIncompleteMultipartUpload>' if $abort;
        $rule .= '</Rule>';
        my $body = '<LifecycleConfiguration '
            . 'xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            . $rule . '</LifecycleConfiguration>';
        my ($status, $rbody) = s3_signed_request($uid, $tenant,
            'PUT', "/$param->{bucket}", 'lifecycle', $body);
        die "lifecycle update failed ($status): $rbody\n"
            if $status != 200;
        return "lifecycle updated on $param->{bucket}";
    }});

__PACKAGE__->register_method({
    name => 'bucket_delete',
    path => 'buckets/{bucket}',
    method => 'DELETE',
    protected => 1,
    description => "Delete a bucket (purge objects).",
    permissions => {
        check => ['perm', '/pool', ['Datastore.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            bucket => { type => 'string' },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        run_ok(['radosgw-admin', 'bucket', 'rm',
            '--bucket', $param->{bucket}, '--purge-objects']);
        return "bucket $param->{bucket} deleted";
    }});

1;
