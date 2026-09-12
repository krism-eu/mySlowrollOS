# microRaku v0.1 specification

## Status

Experimental. The first milestone targets **openSUSE MicroOS only** and must be tested on disposable or recoverable systems before any production claim is made.

## Goal

Provide a persistent native-package layer above the immutable MicroOS `/usr` while keeping the MicroOS base snapshot exclusively managed by `transactional-update`.

## Core invariant

microRaku owns only:

- `/var/lib/microraku`;
- the OverlayFS mount placed on `/usr` at boot;
- package files written into the OverlayFS upper layer.

microRaku does **not** own or directly mutate the active MicroOS lower snapshot.

## Storage layout

```text
/var/lib/microraku/
├── packages.list
├── base-rpmdb/
├── state/
│   ├── base-id
│   ├── last-mount
│   └── last-sync
├── rebuild-pending
├── recreate-pending
├── reset-pending
└── overlay/
    ├── upper/
    ├── work/
    └── previous-upper/
```

`previous-upper` is a single recovery copy retained while a clean rebuild is pending or has failed. It is deleted after successful reconciliation.

## Boot algorithm

1. MicroOS mounts its immutable root and the initrd-visible persistent `/var`.
2. The microRaku dracut hook runs at `pre-pivot`.
3. It identifies the active Btrfs root snapshot from the root mount `FSROOT`.
4. Before overlaying `/usr`, it copies the lower RPM database from `/usr/lib/sysimage/rpm` into `/var/lib/microraku/base-rpmdb` whenever the base snapshot changes.
5. On a new base or rollback, the old active upper is moved to `previous-upper`, a fresh upper/work pair is created, and reconciliation is marked pending.
6. OverlayFS is mounted on `/usr` with the immutable `/usr` as lowerdir and `/var/lib/microraku/overlay/upper` as upperdir.
7. systemd starts normally.
8. If reconciliation is pending, `microraku-sync.service` waits for networking and reconstructs the user layer from `packages.list` using zypper.

## Desired-state model

`packages.list` contains **only explicit package names requested by the user**. Dependencies are deliberately not stored. On reconstruction, zypper resolves dependencies again against the current MicroOS base.

A package may remain in `packages.list` even when a newer MicroOS snapshot starts shipping it. In that case the package is not installed into the upper layer. If a later rollback removes it from the base, reconciliation installs it again automatically.

## Install semantics

`microraku-install`:

- accepts package names only in v0.1;
- refuses a package already provided by the current MicroOS lower RPM database;
- installs with zypper into the merged `/usr` view;
- records the explicit package name only after zypper succeeds.

## Remove semantics

`microraku-remove` does not run `zypper remove` against the live merged filesystem. It removes names from desired state and schedules a clean upper rebuild at the next boot. This avoids producing OverlayFS whiteouts over files provided by the immutable lower layer.

## Reset semantics

`microraku-reset` only creates a reset marker. The initrd performs the destructive reset before `/usr` is overlaid on the next boot.

## Failure model

The dracut hook is fail-safe. If prerequisites are missing, the base RPM database cannot be copied, or OverlayFS fails to mount, boot continues with the clean MicroOS base.

A failed post-boot reconciliation leaves `rebuild-pending` and `previous-upper` intact for diagnosis/retry.

## Important v0.1 limitations

- No support for distributions other than openSUSE MicroOS.
- No local RPM-file installation.
- No offline reconstruction/cache guarantee.
- No package version pinning in desired state.
- No DKMS/kernel package guarantee.
- No automatic protection against package scriptlets modifying `/etc`, `/var`, bootloader state, initrd, users/groups, or other paths outside `/usr`.
- Direct `zypper install/remove` use outside the microRaku wrappers is unsupported because it bypasses desired-state tracking.
- SELinux/AppArmor interactions require dedicated testing.

These limitations are intentional: v0.1 validates the persistent `/usr` overlay and base-reconciliation model before expanding scope.
