SHELL := /bin/sh
RADIX ?= ../radix/build/radix
PACKAGES ?= ../radix-packages
BUILD ?= $(CURDIR)/build
DIST ?= $(CURDIR)/dist

.PHONY: check check-channel qualify-desktop bootstrap live iso iso-console qemu qemu-install clean
check:
	./tools/check-tree

check-channel:
	./tools/check-package-contract '$(PACKAGES)'

qualify-desktop: check-channel
	RADIX='$(RADIX)' PACKAGES='$(PACKAGES)' ./tools/qualify-desktop

bootstrap:
	./scripts/bootstrap-sources.sh

live:
	RADIX='$(RADIX)' PACKAGES='$(PACKAGES)' BUILD='$(BUILD)' ./scripts/build-live.sh

iso: qualify-desktop live
	BUILD='$(BUILD)' DIST='$(DIST)' ./scripts/build-iso.sh

iso-console:
	RADIX_REQUIRE_KDE=0 RADIX='$(RADIX)' PACKAGES='$(PACKAGES)' BUILD='$(BUILD)' ./scripts/build-live.sh
	BUILD='$(BUILD)' DIST='$(DIST)' ./scripts/build-iso.sh

qemu: iso
	DIST='$(DIST)' ./scripts/qemu-smoke.sh

qemu-install: qualify-desktop live
	BUILD='$(BUILD)' ./scripts/qemu-install-smoke.sh

clean:
	rm -rf '$(BUILD)' '$(DIST)' '.cache'
