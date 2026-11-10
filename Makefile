PACKAGE := pve-s3-manager
VERSION := 0.1.2-1
BUILD   := build
STAGE   := $(BUILD)/stage
DEB     := $(BUILD)/$(PACKAGE)_$(VERSION)_all.deb

PERL_FILES := $(shell find PVE -name '*.pm')
JS_FILES   := $(shell find www -name '*.js')
STUBS      := tests/stubs

.PHONY: all lint test deb clean

all: lint deb

lint:
	@awk 'length>100{print FILENAME":"FNR": "length" columns"; bad=1} END{exit bad}' $(PERL_FILES) $(JS_FILES)
	@for f in $(PERL_FILES); do perl -I. -I$(STUBS) -c $$f || exit 1; done
	@for f in $(JS_FILES); do node --check $$f || exit 1; done
	@sh -n scripts/pve-s3-bringup.sh scripts/pve-s3-export.sh scripts/pve-s3-health.sh scripts/lb/pve-s3-lb-deploy.sh
	@cat debian/postinst.head debian/integrate.pl debian/postinst.tail | sh -n
	@cat debian/postrm.head debian/integrate.pl debian/postrm.tail | sh -n
	@echo "lint ok"

test: lint deb
	@tests/test-bringup-stubs.sh
	@dpkg-deb -I $(DEB) | grep -q "Package: $(PACKAGE)" && echo "deb ok: $(DEB)"

deb:
	@mkdir -p $(STAGE)/DEBIAN $(STAGE)/usr/share/perl5 $(STAGE)/usr/share/pve-manager/js
	@mkdir -p $(STAGE)/usr/sbin $(STAGE)/usr/share/pve-s3/lb
	@cp -r PVE $(STAGE)/usr/share/perl5/
	@cp www/manager6/*.js $(STAGE)/usr/share/pve-manager/js/
	@install -m 0755 scripts/pve-s3-bringup.sh $(STAGE)/usr/sbin/pve-s3-bringup
	@install -m 0755 scripts/pve-s3-export.sh $(STAGE)/usr/sbin/pve-s3-export
	@install -m 0755 scripts/pve-s3-health.sh $(STAGE)/usr/sbin/pve-s3-health
	@install -m 0755 scripts/lb/pve-s3-lb-deploy.sh $(STAGE)/usr/sbin/pve-s3-lb-deploy
	@install -m 0644 scripts/lb/haproxy.cfg scripts/lb/keepalived.conf.tmpl $(STAGE)/usr/share/pve-s3/lb/
	@cat debian/postinst.head debian/integrate.pl debian/postinst.tail > $(STAGE)/DEBIAN/postinst
	@cat debian/postrm.head debian/integrate.pl debian/postrm.tail > $(STAGE)/DEBIAN/postrm
	@chmod 0755 $(STAGE)/DEBIAN/postinst $(STAGE)/DEBIAN/postrm
	@printf 'Package: $(PACKAGE)\nVersion: $(VERSION)\nArchitecture: all\nMaintainer: pve-s3 contributors\nDepends: pve-manager, perl, radosgw, haproxy, keepalived\nDescription: S3 object storage management for Proxmox VE\n Manages Ceph RGW gateways, S3 users/keys and buckets\n on a PVE Ceph cluster from the Proxmox web UI.\n' > $(STAGE)/DEBIAN/control
	@dpkg-deb --root-owner-group --build $(STAGE) $(DEB) >/dev/null
	@echo "built $(DEB)"

clean:
	@rm -rf $(BUILD)
