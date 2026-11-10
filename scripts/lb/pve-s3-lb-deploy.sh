#!/bin/sh
# pve-s3-lb-deploy — install/converge HAProxy + keepalived on ONE host.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Usage: pve-s3-lb-deploy.sh <vrrp-priority>
#   cloud1=110 cloud2=100 cloud3=90 (highest wins the VIP)
# Expects in the working directory (or $LB_SRC):
#   haproxy.cfg, keepalived.conf.tmpl, s3.pem, vrrp.pass
# Idempotent: rewrites config, validates, reloads only
# the service whose config changed.
set -eu

PRIORITY=${1:?usage: pve-s3-lb-deploy.sh <vrrp-priority>}
SRC=${LB_SRC:-.}
VIP=${VIP:-192.168.56.100}   # set to your endpoint VIP
IFACE=${IFACE:-vmbr0}

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

if [ ! -x /usr/sbin/haproxy ] || [ ! -x /usr/sbin/keepalived ]; then
    apt-get install -y haproxy keepalived
fi

sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null
printf 'net.ipv4.ip_nonlocal_bind=1\n' > /etc/sysctl.d/99-pve-s3.conf

mkdir -p /etc/pve-s3/tls
install -m 600 "$SRC/s3.pem" /etc/pve-s3/tls/s3.pem

install -m 644 "$SRC/haproxy.cfg" /etc/haproxy/haproxy.cfg.new
if ! cmp -s /etc/haproxy/haproxy.cfg.new /etc/haproxy/haproxy.cfg; then
    haproxy -c -f /etc/haproxy/haproxy.cfg.new
    mv /etc/haproxy/haproxy.cfg.new /etc/haproxy/haproxy.cfg
    systemctl enable haproxy >/dev/null 2>&1 || true
    systemctl restart haproxy
    echo "haproxy: config updated, restarted"
else
    rm -f /etc/haproxy/haproxy.cfg.new
    systemctl is-active --quiet haproxy || systemctl start haproxy
    echo "haproxy: unchanged"
fi

VRRP_PASS=$(cat "$SRC/vrrp.pass")
sed -e "s/@PRIORITY@/$PRIORITY/" -e "s/@VIP@/$VIP/" \
    -e "s/@IFACE@/$IFACE/" -e "s/@PASS@/$VRRP_PASS/" \
    "$SRC/keepalived.conf.tmpl" > /etc/keepalived/keepalived.conf.new
chmod 600 /etc/keepalived/keepalived.conf.new
if ! cmp -s /etc/keepalived/keepalived.conf.new /etc/keepalived/keepalived.conf; then
    mv /etc/keepalived/keepalived.conf.new /etc/keepalived/keepalived.conf
    systemctl enable keepalived >/dev/null 2>&1 || true
    systemctl restart keepalived
    echo "keepalived: config updated, restarted"
else
    rm -f /etc/keepalived/keepalived.conf.new
    systemctl is-active --quiet keepalived || systemctl start keepalived
    echo "keepalived: unchanged"
fi
