# microRaku v0.1 specification

## Status

Experimental. The first milestone targets **openSUSE MicroOS only** and must be tested on disposable or recoverable systems before any production claim is made.

## Goal

Provide a persistent native-package layer above the immutable MicroOS `/usr` while keeping the MicroOS base snapshot exclusively managed by `transactional-update`.

## Core invariant

microRaku owns only:

- `/var/lib/microraku`;
- the OverlayFS mount placed on `/usr` at boot;
- package files and RPM database copy-ups written into the OverlayFS upper layer.

microRaku does **not** directly mutate the active MicroOS lower snapshot.

## Storage layout

```text
/var/lib/microraku/
├── packages.list
├── base-rpmdb/
├── cache/
│   ├── zypp/
│   └── packages/
│       ├── .keep_packages
│       └── .no_auto_prune
├── state/
│   ├── base-id
│   ├── last-mount
│   ├── last-sync
│   ├── modified-base.tsv
│   └── etc-drift.log
├── rebuild-pending
├── recreate-pending
├── reset-pending
└── overlay/
    ├── upper/
    ├── work/
    └── previous-upper/
```

`previous-upper` is a single recovery copy retained while a clean rebuild is pending or has failed. It is deleted only after successful reconciliation.

## Boot algorithm

1. MicroOS mounts its immutable root and the initrd-visible persistent `/var`.
2. The microRaku dracut hook runs at `pre-pivot`.
3. It identifies the active Btrfs root snapshot from the root mount `FSROOT`.
4. Before overlaying `/usr`, it copies the lower RPM database from `/usr/lib/sysimage/rpm` into `base-rpmdb` whenever the base identity changes.
5. On a new base or rollback, the old active upper is preserved, a fresh upper/work pair is created, and reconciliation is marked pending.
6. OverlayFS is mounted on `/usr` with the immutable `/usr` as lowerdir and the persistent upper in `/var`.
7. systemd starts normally.
8. If reconciliation is pending, `microraku-sync.service` reconstructs the user layer from `packages.list`.

## Desired-state model

`packages.list` contains only explicit package names requested by the user. Dependencies are solved again against the current base. A requested package may remain in desired state even if a later MicroOS snapshot starts providing it; in that case microRaku leaves the package to the base. A rollback to a base that no longer provides it makes it eligible for the overlay again.

## Package-manager isolation

microRaku reuses the host repository definitions from `/etc/zypp/repos.d`, but it does not reuse the normal libzypp cache. Metadata and downloaded RPMs are redirected to `/var/lib/microraku/cache`.

The package-cache directory contains `.keep_packages` and `.no_auto_prune`, so libzypp retains downloaded repository RPMs. During a rebuild, microRaku first tries to refresh repository metadata; if refresh fails it retries installation with the retained metadata/cache. This is a best-effort offline path, not a complete historical repository snapshot.

## Install semantics

`microraku-install`:

- accepts package names only;
- refuses explicit installation of packages already provided by the current lower RPM database;
- uses zypper with `solver-focus=Installed`, no forced resolution and no recommends;
- records desired package names only after a successful transaction;
- compares the merged RPM database against the saved lower RPM database;
- records overridden base packages in `state/modified-base.tsv`;
- rejects the transaction if it replaced a critical base component and schedules a clean rebuild for the next boot;
- fingerprints `/etc` before and after the transaction and logs drift.

Critical-base protection currently covers the package-manager/update/boot core such as glibc, rpm, libzypp, zypper, transactional-update, systemd, dracut, snapper, Btrfs/GRUB/shim/kernel families and `aaa_base`/`filesystem`.

## Remove semantics

`microraku-remove` changes desired state and schedules a fresh upper-layer rebuild for the next boot. It intentionally does not call `zypper remove` on the live merged tree, avoiding OverlayFS whiteouts over lower files.

## Reset semantics

`microraku-reset` only creates a reset marker. The initrd performs the destructive reset before `/usr` is overlaid on the next boot. The package cache is not security-sensitive state and may be retained independently.

## Failure model

The dracut hook is fail-safe. Missing prerequisites, an unusable lower RPM database, or an OverlayFS mount failure must not make the machine unbootable; boot continues with the clean MicroOS base.

A failed zypper install/reconciliation schedules a fresh rebuild instead of treating a partially modified upper as authoritative. Desired state and `previous-upper` are retained for diagnosis/retry.

## transactional-update interaction

Normal MicroOS base updates remain owned by `transactional-update`. The expected transition is **stage update → reboot → microRaku detects new lower → rebuild overlay**.

`transactional-update apply` is not part of the supported v0.1 workflow because applying a pending snapshot to the running system can replace the running `/usr` mount view. Reboot is the supported handoff boundary.

## Important v0.1 limitations

- No support for distributions other than openSUSE MicroOS.
- No local RPM-file installation.
- The persistent cache improves offline recovery but is not a complete offline guarantee or repository snapshot.
- Desired state is package-name based, not version-pinned.
- Non-critical base-package overrides are allowed but explicitly reported; this area needs update/rollback testing.
- No DKMS/kernel-package guarantee.
- `/etc` drift is detected but not automatically rolled back.
- No automatic protection against arbitrary package scriptlet changes to `/var`, bootloader state, initrd, users/groups or other paths outside `/usr`.
- Direct `zypper install/remove` outside the microRaku wrappers is unsupported because it bypasses desired-state and safety tracking.
- SELinux/AppArmor interactions require dedicated testing.

These limitations are intentional: v0.1 validates the persistent `/usr` overlay and base-reconciliation model before expanding scope.
