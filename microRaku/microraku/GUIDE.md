# microRaku v0.1 test guide

## Read this first

microRaku changes early boot and overlays `/usr`. v0.1 is experimental. Test on a machine where you can select/rollback MicroOS snapshots or otherwise recover the system.

## Install

From the `microraku/` payload directory:

```bash
sudo ./install.sh
sudo reboot
```

The installer does not write directly into the running read-only `/usr`. It stages files through `transactional-update run`, then rebuilds initrd in the same transactional chain. Persistent state is prepared separately under `/var/lib/microraku`.

## Verify first boot

```bash
findmnt /usr
cat /var/lib/microraku/state/base-id
rpm --dbpath /var/lib/microraku/base-rpmdb -qa | head
systemctl status microraku-sync.service
```

`findmnt /usr` should report `overlay` as the filesystem type.

Useful boot logs:

```bash
journalctl -b | grep -i microraku
journalctl -b -u microraku-sync.service
```

## Install a native package

Use a package that is not part of the MicroOS base:

```bash
sudo microraku-install htop
microraku-list
```

Do not use plain `zypper install` for microRaku-managed packages in v0.1; it would bypass desired-state tracking.

## Remove a package

```bash
sudo microraku-remove htop
sudo reboot
```

Removal is intentionally applied by rebuilding the upper layer on the next boot rather than creating live OverlayFS whiteouts.

## Reset

```bash
sudo microraku-reset
sudo reboot
```

The command only schedules the reset. The initrd deletes the old layer safely before mounting `/usr`.

## Disable for one boot

Add one of these kernel arguments temporarily from the bootloader:

```text
microraku=0
```

or

```text
nomicroraku
```

The system should boot the clean MicroOS base without the persistent overlay.

## Base update test

1. Confirm a microRaku package is installed.
2. Perform the normal MicroOS transactional update.
3. Reboot into the new snapshot.
4. Confirm `/usr` is overlaid again.
5. Confirm `base-id` changed.
6. Confirm the tracked package was restored (unless the new base itself now provides it).
7. Inspect `journalctl -b -u microraku-sync.service`.

## Rollback test

Rollback MicroOS using its normal supported mechanism, reboot, and repeat the checks above. microRaku treats rollback exactly like any other base change: fresh upper, new lower RPM DB snapshot, desired-state reconciliation.

## Recovery data

When the base changes or a clean rebuild is requested, microRaku retains one old upper layer at:

```text
/var/lib/microraku/overlay/previous-upper
```

It is removed only after successful reconciliation.

## Known limitation: package scriptlets

OverlayFS covers `/usr`, not the whole operating system. RPM scriptlets can modify `/etc`, `/var`, users/groups, initrd or boot state. v0.1 does not automatically roll those side effects back. Prefer simple user-space packages during early testing.
