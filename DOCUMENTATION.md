# Radix GNU/Linux Documentation

The README covers the normal build and install path. The notes here are for working on the image itself and cover the installer, boot layout, current status, CI, security boundaries, and release checks.

## Build and source layout

Radix GNU/Linux is built from three repositories:

    https://github.com/radix-gnu-linux/radix
    https://github.com/radix-gnu-linux/radix-packages
    https://github.com/radix-gnu-linux/radix-linux

`radix` is the package and system manager. `radix-packages` is the package channel. `radix-linux` contains the live image, installer, boot integration, system profiles, VM tests, and release automation.

The normal local checkout layout is:

    radix/
    radix-packages/
    radix-linux/

From `radix-linux`, run:

    make check
    make check-channel
    sudo make iso

`make check` validates shell and Python syntax, workflow YAML when PyYAML is available, required source files, installer module loading, account generation, activation fixtures, and GPT generation. `make check-channel` verifies that the base and KDE package IDs exist in the active package repository.

The build uses canonical `/radix/store` paths because store paths are part of package identity. Root access is normally required unless `/radix` is already writable. The host dependency check is:

    ./scripts/check-host.sh build

If adjacent source trees are unavailable, run:

    ./scripts/bootstrap-sources.sh

That helper maintains clones under `.cache/sources` and prints `RADIX` and `PACKAGES` values for the build. To build and install only the core executable, run:

    sudo ./scripts/bootstrap-radix.sh

For console-only development without the KDE release contract, run:

    sudo make iso-console

The normal release path always sets `RADIX_REQUIRE_KDE=1`. Build intermediates go to `build/`; the named ISO, `radix-live.iso` alias, SHA-256 files, and `build-info.json` go to `dist/`. `BUILD` and `DIST` may be overridden as Make variables.

## Installer behavior

The live image starts in a console rescue environment. Launch the installer with:

    setup-radix

Run a non-destructive hardware and package preflight with:

    setup-radix --dry-run

The guided installer currently targets x86_64 UEFI machines and one whole target disk. It writes a GPT containing a 512 MiB EFI system partition, optional swap, and a root partition. The closed rescue image always includes the static BusyBox ext2 formatter. ext4 and btrfs are offered only when their formatters are present in the image.

Before writing a partition table, the installer verifies the selected kernel and every package required by the chosen profile against the store embedded in the ISO. A KDE selection includes the graphics, Qt, Plasma, SDDM, and audio packages listed in `profiles/kde.packages`.

The final erase prompt displays the target path, model, and size and requires the user to enter the complete device path. The installer then:

1. Writes and formats the disk.
2. Copies the verified Radix store.
3. Composes the target system at canonical `/radix`.
4. Creates account files outside the immutable store.
5. Configures OpenRC, networking, and the selected desktop.
6. Builds the installed-system initramfs.
7. Installs the UEFI fallback loader.
8. Preserves the package and distribution snapshots on the installed system.

The boot entry locates the root filesystem by GPT `PARTUUID`.

### Networking and offline installation

If the live system is already online, setup records that the official channels are reachable. Otherwise it tries wired DHCP with `dhcpcd`, when present, or BusyBox `udhcpc`. Wi-Fi setup is offered only when `iw`, `wpa_supplicant`, and `wpa_passphrase` are present.

No network connection is required. To disable the GitHub reachability probe, run:

    setup-radix --offline

Installation always uses the package snapshot embedded in the ISO. It never replaces that snapshot with a moving branch during setup because the embedded store was built from the original snapshot.

### Desktop and graphics choices

KDE is the first and default desktop choice and currently requires glibc. Selecting musl changes the installation to the experimental console base.

With `GPU_DRIVER=auto`, NVIDIA hardware uses `drivers/nvidia` when that recipe is embedded in the ISO. Otherwise, setup selects the Mesa path before the disk is touched.

SDDM is configured for Wayland with KWin as the greeter compositor. The installer writes machine-local OpenRC activation wrappers for eudev, D-Bus, NetworkManager, seatd, elogind, polkit, BlueZ, and SDDM. UPower, UDisks2, desktop portals, and session services remain available through their normal D-Bus or user-session activation paths. Setup verifies these paths in the merged profile before erasing the disk.

The release defaults currently record Plasma 6.7.4 and Frameworks 6.28.0. Source versions, hashes, and recipes remain in `radix-packages`.

### Accounts

A KDE installation requires a normal user. The interactive installer asks for the password twice. Administrator users join `wheel` and receive the standard sudo rule. Desktop users also join the audio, video, input, and render groups.

Account hashes are stored under:

    /var/lib/radix/accounts

The passwd and group files under `/etc` refer to that state, keeping account hashes outside immutable store identities.

### Answer files

Automated installation uses:

    setup-radix --answers=/path/to/install.conf --non-interactive

Destructive non-interactive installation requires an exact target match:

    DISK=/dev/vda
    ERASE_CONFIRM=/dev/vda

`examples/ci-install.conf` is intended only for the disposable VM test and must not be used on a physical machine.

### Installed paths

Important paths after reboot include:

    /radix/bin/radix
    /radix/bin/radix-channel-sync
    /etc/radix/system.janet
    /etc/radix/channels.conf
    /var/lib/radix/repository
    /var/lib/radix/distro

`radix-channel-sync` refreshes the official `radix-linux` and `radix-packages` snapshots. It does not replace store verification, source hashes, or a signed update protocol.

## Architecture

### Canonical store composition

Radix store paths are not relocatable. `/radix/store/...` is part of package identity, so the installer does not compose another store under `/mnt/radix/radix`. It copies the verified live store to the target, bind-mounts the target `radix` directory over canonical `/radix`, creates and verifies the target generation, and removes the bind mount before unmounting the disk.

### Live boot

The live initramfs consists of two concatenated `newc` archives. Radix creates the first archive with the small bootable live system. The second adds the installer source, package-channel snapshot, immutable store closures required by selectable profiles, standalone UEFI GRUB image, and rescue-shell configuration. Store objects are copied without modification.

A release ISO carries the KDE installation closure while keeping the live environment console-based. This allows the installer to remain available when graphics are the component being diagnosed. `profiles/kde.packages` is the release contract between this repository and `radix-packages`.

### Installed boot

The installed initramfs contains static BusyBox and `/init`. PID 1 mounts dev, proc, and sys; resolves the root `PARTUUID`; mounts the real root; creates `/run`; points `/run/current-system` to the selected Radix generation; moves the kernel filesystems; and calls `switch_root` into the generated system init.

OpenRC is the normal installed PID 1 handoff. Machine-specific activation files remain under `/etc` rather than package outputs, so package identities stay immutable while service activation remains editable.

### Machine-local state and trust boundary

Machine-local state includes account hashes, `/radix/bin/radix`, the embedded package snapshot, and a copy of the `radix-linux` tree. Official channel addresses are stored in `/etc/radix/channels.conf`:

    https://github.com/radix-gnu-linux/radix-linux
    https://github.com/radix-gnu-linux/radix-packages
    https://github.com/radix-gnu-linux/radix

The `/radix/bin/radix` copy is bootstrap plumbing. The intended end state is for Radix itself to become an ordinary store package built by the self-hosted Radix toolchain.

## Package contract

The base and KDE package IDs are defined in `profiles/base.packages` and `profiles/kde.packages`. Check an adjacent package checkout with:

    ./tools/check-package-contract ../radix-packages

The command reports missing active recipes and identifies recipes that exist only under `ports/`. Required desktop packages should not be removed from the contract merely to make a release build pass.

## GitHub Actions

The quick workflow is `.github/workflows/check.yml`. It runs for pull requests, pushes, and manual dispatches. It has read-only repository permission, per-ref concurrency, a 15-minute timeout, and installs Lua and PyYAML before running `make check`.

The full workflow is `.github/workflows/build-iso.yml`. It runs on pushes to `main`, `v*` tags, a weekly schedule, manual dispatches, and `repository_dispatch` events named `packages-updated` or `radix-updated`. Pull requests use only the quick workflow because a complete KDE source build is too expensive for every review update.

The image job:

1. Checks out the distribution, Radix, and package repositories without persisted credentials.
2. Rejects a tag unless `GITHUB_REF_NAME` equals `v` followed by `VERSION`.
3. Downloads Janet 1.41.2 and verifies SHA-256 `168e97e1b790f6e9d1e43685019efecc4ee473d6b9f8c421b49c195336c0b725` before compiling it.
4. Runs source checks, the Radix release gate, package contract checks, and desktop qualification.
5. Builds the live and installation payload.
6. Boots the ISO in QEMU.
7. Installs to a disposable virtual disk and reboots it through UEFI.
8. Verifies image checksums and uploads the build artifacts.

Official checkout and artifact actions are pinned to reviewed release commits. The large build job has only `contents: read`; a separate tag-only publishing job has `contents: write`. That job downloads the tested artifact, verifies its checksums again, and creates or updates the matching GitHub release.

Successful image artifacts are retained for 30 days. Build logs are retained for 14 days when available. The heavy job has a six-hour timeout and removes large preinstalled runner toolchains to recover disk space.

The sibling repository checkouts currently resolve their default branches. `build-info.json` records the exact three revisions used for each artifact, but rebuilding an older distribution tag later may select newer sibling revisions unless a coordinated cross-repository ref policy is introduced.

## Security

### Reporting

Use GitHub private security reporting for issues that could expose data, bypass erase confirmation, write to the wrong disk, weaken account handling, or let untrusted package input cross a privilege boundary. Include the affected revision, machine or VM layout, a minimal reproduction, and whether a real disk was changed.

If private reporting is unavailable, open a minimal public issue requesting a private contact method. Do not publish exploit details, disk contents, password material, or sensitive logs.

### Disk safety

Do not distribute an ISO that has not passed the install-and-reboot VM test. The answer-file path requires `ERASE_CONFIRM` to match the selected disk exactly, and the interactive path prints the disk again before writing. These checks are part of the installer safety boundary.

Disk discovery, GPT generation, mounting, boot files, account hashes, and the canonical `/radix` bind should be treated as security-sensitive code even when a defect is not remotely exploitable.

### Update and build trust

`radix-channel-sync` follows the official GitHub `main` snapshots over HTTPS, but it is not a signed channel protocol. It must not be treated as authenticated channel generations or signed binary substitutes.

The live image still has stage-0 trust edges: host tools build the initial kernel and static userspace, and a static Radix executable is copied into the installed machine outside the immutable store. Release images record exact source revisions for traceability, but revision metadata does not make an unsigned channel signed.

Workflow checkouts disable persisted credentials. Package build scripts run in the read-only build job and never receive the release publishing credential.

## Current status

Implemented and covered by the current image path:

- x86_64 UEFI whole-disk installation.
- GPT generation with primary and backup CRC checks.
- Refusal of mounted target disks and 4Kn devices.
- Formatter-aware ext2, ext4, and btrfs choices.
- Package and store preflight before erase.
- KDE-first installation with glibc and an experimental musl console path.
- LTS and stable kernel choices.
- Wired DHCP and conditional Wi-Fi setup.
- Automatic NVIDIA or Mesa selection.
- User, password, administrator, and desktop group setup.
- OpenRC activation for the boot-critical desktop path.
- Canonical `/radix/store` target composition.
- A `PARTUUID`-based installed initramfs and fallback UEFI GRUB image.
- Offline package and distribution snapshots with channel metadata.
- Live boot and destructive install-and-reboot QEMU tests.
- GitHub image builds with recorded source revisions and verified checksums.

Important unfinished work:

- A closed self-hosting compiler and toolchain bootstrap.
- Signed update channels and binary substitutes.
- Secure Boot.
- Encrypted and LVM guided layouts.
- BIOS installation.
- Laptop power and suspend qualification.
- Broad Wi-Fi, graphics, and audio hardware testing.
- Complete proprietary NVIDIA kernel-module qualification.
- Sufficient package coverage for a generally stable desktop release.

The largest external gate remains `radix-packages`. `make iso` requires the IDs in `profiles/kde.packages` to be active. If required recipes remain only under `ports/`, the release build stays red.

## Release checklist

Before attaching an ISO to a public release:

- Confirm that `VERSION` matches the release tag and image name.
- Confirm that `README.md` and `DOCUMENTATION.md` describe the image being shipped.
- Build from clean or fully understood source revisions and `/radix` state.
- Run `make check`.
- Run `make check-channel`.
- Run Radix core `make release-gate`.
- Run `radix-packages` `./tools/check-tree`.
- Confirm that the KDE package contract has no missing recipes.
- Run `make qualify-desktop` and pass the merged-profile and ELF-closure audit.
- Build with `RADIX_REQUIRE_KDE=1`.
- Run `make qemu` and reach the live Radix PID 1 marker.
- Run `make qemu-install` and complete installation to its disposable disk.
- Confirm that the installed UEFI disk reaches `switch_root` and the Radix PID 1 marker.
- Confirm that OpenRC reaches its default runlevel and starts the elogind, polkit, and SDDM paths.
- Verify installed `/radix/bin/radix --version`.
- Run `radix system verify` on the installed disk.
- Create another generation and test rollback.
- Confirm that networking returns after reboot.
- Verify every downloaded ISO against its published SHA-256 file.
- Confirm that `build-info.json` contains all three source revisions.
- Record every skipped gate and known limitation in the release notes.

Before calling an image generally usable, test Intel, AMD, and NVIDIA graphics; Wi-Fi; audio; suspend and resume; shutdown and reboot; updates; rollback; and at least one laptop and one desktop on physical hardware.

## License

Unless otherwise noted, the original material in this repository is licensed under the GNU General Public License version 3 or later. `COPYING` contains the canonical GPL version 3 text. Upstream and embedded packages retain their own licenses.
