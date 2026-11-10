#!/usr/bin/perl
# Integration patcher for stock pve-manager files.
# Applies (mode "apply", from postinst) or removes
# (mode "remove", from postrm) the three integration
# points in INTEGRATION.md. Idempotent, .pve-s3.bak
# backups, skipped with a warning when an anchor no
# longer matches; never fails the install.
use strict;
use warnings;

my ($mode, $prefix) = @ARGV;
$prefix //= '';
if (!defined $mode || ($mode ne 'apply' && $mode ne 'remove')) {
    print STDERR "usage: integrate.pl apply|remove [prefix]\n";
    exit 0;
}

my sub slurp {
    my ($file) = @_;
    open(my $fh, '<', $file) or return undef;
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}

my sub write_atomic {
    my ($file, $data) = @_;
    my $tmp = "$file.pve-s3.tmp";
    open(my $fh, '>', $tmp) or return 0;
    print {$fh} $data;
    close($fh) or return 0;
    return rename($tmp, $file);
}

my sub backup_once {
    my ($file) = @_;
    my $bak = "$file.pve-s3.bak";
    return if -e $bak;
    my $data = slurp($file);
    write_atomic($bak, $data) if defined $data;
}

my sub run_patch {
    my ($patch) = @_;
    my $file = $patch->{file};
    if (!-f $file) {
        print STDERR "pve-s3: $file not found, skipping\n";
        return;
    }
    my $src = slurp($file);
    if (!defined $src) {
        print STDERR "pve-s3: cannot read $file, skipping\n";
        return;
    }
    my $marker = $mode eq 'remove'
        ? ($patch->{marker_remove} // $patch->{marker})
        : $patch->{marker};
    my $has = index($src, $marker) >= 0;
    $has = !$has if $patch->{invert};
    return if $mode eq 'apply' && $has;
    return if $mode eq 'remove' && !$has;
    my $new = $patch->{$mode}->($src);
    if (!defined $new || $new eq $src) {
        if (!$patch->{quiet_skip}) {
            print STDERR "pve-s3: anchor not found in $file, "
                . "integration step skipped (see INTEGRATION.md)\n";
        }
        return;
    }
    backup_once($file) if $mode eq 'apply';
    if (write_atomic($file, $new)) {
        my $past = $mode eq 'apply' ? 'applied' : 'removed';
        print "pve-s3: $past integration in $file\n";
    } else {
        print STDERR "pve-s3: cannot write $file, skipping\n";
    }
}

my $pm = "$prefix/usr/share/perl5";
my $js = "$prefix/usr/share/pve-manager/js";
my $tpl = "$prefix/usr/share/pve-manager/index.html.tpl";

my $api_use = "use PVE::API2::Cluster::S3;\n";
my $api_block = "\n__PACKAGE__->register_method ({\n"
    . "    subclass => \"PVE::API2::Cluster::S3\",\n"
    . "    path => 's3',\n});\n";
run_patch({
    file => "$pm/PVE/API2/Cluster.pm",
    marker => 'PVE::API2::Cluster::S3',
    apply => sub {
        my ($src) = @_;
        my $use_anchor = "use PVE::API2::Cluster::Ceph;\n";
        my $reg_anchor = "    path => 'ceph',\n});\n";
        return undef if index($src, $use_anchor) < 0
            || index($src, $reg_anchor) < 0;
        $src =~ s/\Q$use_anchor\E/$use_anchor$api_use/;
        $src =~ s/\Q$reg_anchor\E/$reg_anchor$api_block/;
        return $src;
    },
    remove => sub {
        my ($src) = @_;
        $src =~ s/\Q$api_use\E//;
        $src =~ s/\Q$api_block\E//;
        return $src;
    },
});

use Digest::MD5 qw(md5_hex);
my $jsver = 'dev';
if (open my $jh, '<', "$js/PVES3Workspace.js") {
    local $/;
    my $data = <$jh>;
    close $jh;
    $jsver = substr(md5_hex($data), 0, 8) if defined $data && length $data;
}
my $script_tag = '    <script type="text/javascript" '
    . 'src="/pve2/js/PVES3Workspace.js?ver=[% version %]'
    . "-pves3-$jsver\">"
    . "</script>\n";
run_patch({
    file => $tpl,
    marker => "-pves3-$jsver",
    marker_remove => 'PVES3Workspace.js',
    apply => sub {
        my ($src) = @_;
        if ($src =~ s{    <script type="text/javascript" src="/pve2/js/PVES3Workspace\.js\?ver=\[% version \%\](?:-pves3-[^"]*)?"></script>\n}{$script_tag}) {
            return $src;
        }
        my $anchor = '/pve2/js/pvemanagerlib.js';
        my $pos = index($src, $anchor);
        return undef if $pos < 0;
        my $eol = index($src, "\n", $pos);
        return undef if $eol < 0;
        substr($src, $eol + 1, 0) = $script_tag;
        return $src;
    },
    remove => sub {
        my ($src) = @_;
        $src =~ s/ *<script type="text\/javascript" src="\/pve2\/js\/PVES3Workspace\.js\?ver=[^"]*"><\/script>\n//;
        return $src;
    },
});

# S3 is grouped like Permissions: one parent page
# (status, itemId 's3', expanded) plus one child page
# per section tagged groups: ['s3'].
my @s3_children = (
    ['pveS3GatewaysView', 'Gateways', 'fa fa-server', 's3-gateways'],
    ['pveS3TenantsView', 'Tenants', 'fa fa-users', 's3-tenants'],
    ['pveS3UsersView', 'Users & Keys', 'fa fa-key', 's3-users'],
    ['pveS3BucketsView', 'Buckets & Usage', 'fa fa-database', 's3-buckets'],
);
run_patch({
    file => "$js/pvemanagerlib.js",
    marker => 'pveS3StatusView',
    marker_remove => 'pveS3',
    apply => sub {
        my ($src) = @_;
        my $id = index($src, "itemId: 'ceph',");
        return undef if $id < 0;
        my $eol = index($src, "\n", $id);
        my ($field) = substr($src, rindex($src, "\n", $id) + 1,
            $eol - rindex($src, "\n", $id) - 1) =~ /^([ \t]*)/;
        my $rest = substr($src, $eol + 1);
        return undef if $rest !~ /\A.*?^([ \t]*)\},\n/ms;
        my $open = $1;
        my $block = "$open\{\n"
            . "${field}xtype: 'pveS3StatusView',\n"
            . "${field}title: gettext('S3 Object Storage'),\n"
            . "${field}iconCls: 'fa fa-database',\n"
            . "${field}itemId: 's3',\n"
            . "${field}expandedOnInit: true,\n"
            . "$open\},\n";
        for my $child (@s3_children) {
            my ($xtype, $title, $icon, $item) = $child->@*;
            $block .= "$open\{\n"
                . "${field}xtype: '$xtype',\n"
                . "${field}title: gettext('$title'),\n"
                . "${field}iconCls: '$icon',\n"
                . "${field}groups: ['s3'],\n"
                . "${field}itemId: '$item',\n"
                . "$open\},\n";
        }
        $rest =~ /\A.*?^[ \t]*\},\n/ms;
        my $at = $eol + 1 + $+[0];
        substr($src, $at, 0) = $block;
        return $src;
    },
    remove => sub {
        my ($src) = @_;
        $src =~ s/[ \t]*\{\n[ \t]*xtype: 'pveS3\w+View',\n(?:[ \t]*.*\n)*?[ \t]*itemId: 's3[a-z-]*',\n[ \t]*\},\n//g;
        $src =~ s/[ \t]*\{\n[ \t]*xtype: 'pveDcS3View',\n[ \t]*title: gettext\('S3 Object Storage'\),\n[ \t]*iconCls: 'fa fa-database',\n[ \t]*itemId: 's3',\n[ \t]*\},\n//;
        return $src;
    },
});

# One-time migration: remove the pre-grouping single
# S3 entry (pveDcS3View). Runs on every install until
# the legacy block is gone; harmless afterwards.
run_patch({
    file => "$js/pvemanagerlib.js",
    marker => 'pveDcS3View',
    marker_remove => 'pveDcS3View-never-present',
    invert => 1,
    quiet_skip => 1,
    apply => sub {
        my ($src) = @_;
        my $new = $src;
        $new =~ s/[ \t]*\{\n[ \t]*xtype: 'pveDcS3View',\n[ \t]*title: gettext\('S3 Object Storage'\),\n[ \t]*iconCls: 'fa fa-database',\n[ \t]*itemId: 's3',\n[ \t]*\},\n//;
        return $new;
    },
    remove => sub {
        my ($src) = @_;
        return $src;
    },
});

exit 0;
