SHELL := /bin/sh
RADIX ?= ../radix/build/radix
PACKAGES ?= ../radix-packages
BUILD ?= $(CURDIR)/build
DIST ?= $(CURDIR)/dist

.PHONY: check check-channel qualify-desktop bootstrap kde-preview live iso iso-native iso-console iso-preview qemu qemu-install clean
check:
	./tools/check-tree

check-channel:
	./tools/check-package-contract '$(PACKAGES)'

qualify-desktop: check-channel
	RADIX='$(RADIX)' PACKAGES='$(PACKAGES)' ./tools/qualify-desktop

bootstrap:
	./scripts/bootstrap-sources.sh

kde-preview:
	BUILD='$(BUILD)' ./scripts/build-kde-preview-rootfs.sh

live:
	RADIX='$(RADIX)' PACKAGES='$(PACKAGES)' BUILD='$(BUILD)' ./scripts/build-live.sh

# Native release ISO. This remains strict and only succeeds once KDE is fully
# supplied by radix-packages.
iso-native: qualify-desktop live
	BUILD='$(BUILD)' DIST='$(DIST)' ./scripts/build-iso.sh

iso: iso-native

# Small bring-up image without a desktop payload.
iso-console:
	RADIX_REQUIRE_KDE=0 RADIX_KDE_PREVIEW=0 RADIX='$(RADIX)' PACKAGES='$(PACKAGES)' BUILD='$(BUILD)' ./scripts/build-live.sh
	BUILD='$(BUILD)' DIST='$(DIST)' ./scripts/build-iso.sh

# Installable KDE test image. While native KDE recipes are incomplete this
# bundles a stage-0 KDE/OpenRC userspace on the ISO, but still installs the
# Radix kernel, store, channels and system generation.
iso-preview: kde-preview
	RADIX_REQUIRE_KDE=0 RADIX_KDE_PREVIEW=1 RADIX='$(RADIX)' PACKAGES='$(PACKAGES)' BUILD='$(BUILD)' ./scripts/build-live.sh
	BUILD='$(BUILD)' DIST='$(DIST)' ./scripts/build-iso.sh

qemu: iso-preview
	DIST='$(DIST)' ./scripts/qemu-smoke.sh

qemu-install: iso-preview
	BUILD='$(BUILD)' DIST='$(DIST)' ./scripts/qemu-install-smoke.sh

clean:
	rm -rf '$(BUILD)' '$(DIST)' '.cache'
