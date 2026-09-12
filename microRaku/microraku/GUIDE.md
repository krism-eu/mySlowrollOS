# microRaku v0.1 test guide

## Read this first

microRaku changes early boot and overlays `/usr`. v0.1 is experimental. Test on a machine where you can select/rollback MicroOS snapshots or otherwise recover the system.

## Install

From the payload directory:

```bash
sudo ./install.sh
sudo reboot
```

The installer stages its `/usr` files through `transactional-update run`, rebuilds initrd in the same transactional chain and prepares persistent state/cache separately under `/var/lib/microraku`.

## Verify first boot

```bash
findmnt /usr
cat /var/lib/microraku/state/base-id
rpm --dbpath /var/lib/microraku/base-rpmdb -qa | head
systemctl status microraku-sync.service
```

`findmnt /usr` should report `overlay` as the filesystem type.

Useful logs:

```bash
journalctl -b | grep -i microraku
journalctl -b -u microraku-sync.service
```

## Install a native package

Start with a simple user-space package not present in the MicroOS base:

```bash
sudo microraku-install htop
microraku-list
```

The wrapper keeps libzypp metadata and repository RPMs in:

```text
/var/lib/microraku/cache/
```

Do not use plain `zypper install` for microRaku-managed packages; it bypasses desired-state and safety tracking.

## Inspect safety state

```bash
cat /var/lib/microraku/state/modified-base.tsv 2>/dev/null || true
cat /var/lib/microraku/state/etc-drift.log 2>/dev/null || true
```

`modified-base.tsv` shows lower packages shadowed by different versions in the overlay. Critical package-manager/update/boot/kernel overrides are rejected automatically and schedule a clean rebuild.

`etc-drift.log` means an RPM transaction changed `/etc`. This is a warning requiring inspection, not an automatic rollback.

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

The command only schedules the reset. The initrd deletes the active package layer safely before mounting `/usr`.

## Disable for one boot

Add one of these kernel arguments temporarily:

```text
microraku=0
```

or:

```text
nomicroraku
```

The system should boot the clean MicroOS base without the persistent overlay.

## Base update test

1. Confirm a microRaku package is installed.
2. Perform the normal MicroOS transactional update.
3. **Reboot** into the new snapshot; do not use `transactional-update apply` for this v0.1 test.
4. Confirm `/usr` is overlaid again.
5. Confirm `base-id` changed.
6. Confirm the tracked package was restored, unless the new base now provides it.
7. Inspect `microraku-list`, `modified-base.tsv`, `etc-drift.log` and the sync journal.

## Rollback test

Rollback MicroOS using its supported mechanism, reboot, and repeat the checks above. microRaku treats rollback as another base change: fresh upper, new lower RPM DB snapshot and desired-state reconciliation.

## Network/cache test

After one successful installation, confirm RPM files exist below `/var/lib/microraku/cache/packages`. A rebuild will reuse retained metadata/packages when possible. Do not yet treat this as a guaranteed offline restore: repository metadata and dependency compatibility can still invalidate old artifacts.

## Recovery data

When the base changes or a clean rebuild is requested, microRaku retains one old upper layer at:

```text
/var/lib/microraku/overlay/previous-upper
```

It is removed only after successful reconciliation.

## Known limitation: package scriptlets

OverlayFS covers `/usr`, not the whole operating system. RPM scriptlets can modify `/etc`, `/var`, users/groups, initrd or boot state. v0.1 detects `/etc` drift but cannot automatically roll back arbitrary side effects. Prefer simple user-space packages during early testing.
