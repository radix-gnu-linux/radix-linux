# Radix GNU/Linux

This is the repository that turns Radix into something bootable. It contains the live image, Lua installer, boot setup, package profiles, VM tests, and the workflow that builds release ISOs.

The related repositories have separate responsibilities:

    https://github.com/radix-gnu-linux/radix
    https://github.com/radix-gnu-linux/radix-packages
    https://github.com/radix-gnu-linux/radix-linux

`radix` handles packages and system generations. `radix-packages` holds the recipes. This tree joins the two and supplies the installer. KDE Plasma on Wayland is the default target, while the console image is kept for development and hardware bring-up.

The project is still under active development. Read [DOCUMENTATION.md](DOCUMENTATION.md) before installing or publishing an image; it describes the destructive installer, architecture, current limitations, CI design, security model, and release checklist.

## Repository layout

- `installer/` contains the guided installer and its Lua modules.
- `live/` defines the rescue system included in the live image.
- `profiles/` lists the base, live, and KDE package contracts.
- `scripts/` contains build, boot, installation, bootstrap, and removable-media helpers.
- `tools/` contains source checks, package-contract checks, and test programs.
- `sbin/` contains commands installed into the live or target system.
- `examples/` contains interactive and disposable-VM answer files.

## Build an image

For the normal local layout, keep the three repositories beside one another:

    radix/
    radix-packages/
    radix-linux/

Then run:

    make check
    make check-channel
    sudo make iso

The build uses canonical `/radix/store` paths, so it normally needs root access unless the current user can already write `/radix`. Run this first to identify missing host tools:

    ./scripts/check-host.sh build

If the sibling repositories are unavailable, this helper clones the official Radix and package repositories into `.cache/sources` and prints suitable build paths:

    ./scripts/bootstrap-sources.sh

To build and install only the Radix executable as `/usr/local/bin/radix`, use:

    sudo ./scripts/bootstrap-radix.sh

The console-only development image does not require the KDE package contract:

    sudo make iso-console

Normal release builds always use `RADIX_REQUIRE_KDE=1`. Finished images, checksums, and `build-info.json` are written to `dist/`; intermediate files are written to `build/`.

## Install Radix

Boot the ISO and start the guided installer:

    setup-radix

Run the preflight without changing a disk:

    setup-radix --dry-run

The guided path currently supports x86_64 UEFI systems and installs to one whole disk. It validates the selected package closure before presenting a destructive confirmation that requires the complete target device path. Installation does not require network access and always uses the package snapshot embedded in the ISO.

## Test an image

Boot the live ISO in QEMU:

    make qemu

Install to a disposable virtual disk and reboot it through UEFI:

    sudo make qemu-install

The install-and-reboot test is required before testing a new image on physical hardware.

## Write an image to USB

The USB helper accepts an ISO and a whole block device:

    sudo ./scripts/flash-usb.sh dist/radix-live.iso /dev/sdX

Replace `/dev/sdX` with the correct whole device. The helper requires the full device path again before it unmounts partitions and overwrites the target.

## GitHub releases

Pushes to `main`, weekly schedules, manual dispatches, package update dispatches, and `v*` tags run the full image workflow. A tag is accepted only when it equals `v` followed by the exact contents of `VERSION`.

For example, after setting `VERSION` to `0.2.0`:

    git tag v0.2.0
    git push origin v0.2.0

The workflow builds and qualifies the package closure, boots the live ISO, installs to a disposable VM, reboots the installed disk, verifies checksums, and only then publishes release assets.

## License

Unless otherwise noted, this repository is licensed under the GNU General Public License version 3 or later. See [LICENSE](LICENSE) and the complete license text in [COPYING](COPYING). Embedded and upstream packages retain their own licenses.
