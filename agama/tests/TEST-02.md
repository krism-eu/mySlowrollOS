# Test 02 — actual final profile

Run from a checkout/archive of the reviewed commit in an Agama 24 live VM:

```sh
bash agama/tests/run-test02.sh
```

The runner uses the single generated profile-final.jsonnet directly,
checks downloaded pinned scripts against local files byte-for-byte, and
validates their syntax. The audit loads/probes configuration but never
calls agama install.
An existing UI storage proposal can still exist: inspect it before installation.

Select only the disposable VM disk manually, choose the intended EFI/Btrfs/home
layout without disk swap, and create the user/credentials in the UI.
Complete installation in the UI and reboot into the installed VM.
The profile sets bootloader.updateNvram=true to let Agama register the
installed system's UEFI boot entry after manual storage selection. In the VM,
check that the chosen EFI partition has the GPT ESP type and that the entry is
created; firmware boot order may change. Do not assume the profile selects or
corrects the EFI partition automatically.

## Installed-system acceptance

Run these commands in a terminal as the user created by Agama (not root):

```sh
id
getent group wheel
sudo -n true
zramctl
swapon --show
```

Expect wheel membership, sudo exit status 0, active /dev/zram0 with zstd, and no
disk swap for the chosen no-disk-swap layout. Logical zram size is half RAM,
capped at 4 GiB; it is not 4 GiB on a smaller VM.

With administration verified:

```sh
sudo visudo -c
cat /etc/zypp/repos.d/home_krism.repo
test -s /etc/zypp/repos.d/home_krism.key
sudo zypper --non-interactive refresh home_krism
systemctl get-default
readlink -f /etc/systemd/system/display-manager.service
systemctl is-active sddm.service
systemctl --failed
cat /etc/kernel/cmdline
cat /proc/cmdline
findmnt -no SOURCE,FSTYPE,OPTIONS /
bootctl status
sudo aa-status
```

Expect gpgcheck=1, repo_gpgcheck=1, the local gpgkey path, successful repository
refresh without interactive key acceptance, graphical.target, native sddm.service
and an active graphical login. Check root mount/subvolume and bootloader entries
against the layout actually selected; do not assume a fixed subvolume number.
AppArmor must be active as intended; package presence alone is not proof.

The shipped cmdline is short. Verify the *effective* boot parameters and root
mount before treating it as safe. Inspect first-boot errors with
`journalctl -b -u agama-scripts.service` and repeat key runtime checks after another
reboot. Record outputs and installed RPM versions. A clean profile probe alone
does not satisfy this acceptance test.

## Snapper root retention (tested locally; Agama VM still required)

The reviewed workstation test kept four ordinary snapshots (two complete
pre/post pairs) after `snapper -c root cleanup number`, with the active
snapshot 1 preserved. Confirm the same settings on the fresh Agama VM:

```sh
sudo snapper -c root get-config | grep -E 'NUMBER_CLEANUP|NUMBER_LIMIT|NUMBER_MIN_AGE|TIMELINE_CREATE|EMPTY_PRE_POST_CLEANUP'
sudo snapper -c root list
grep -E '^(SUBVOLUME|FSTYPE|QGROUP|NUMBER_LIMIT|NUMBER_LIMIT_IMPORTANT)=' /etc/snapper/configs/root
```

Expected: NUMBER_CLEANUP=yes, NUMBER_LIMIT=4-4,
NUMBER_LIMIT_IMPORTANT=0-0, NUMBER_MIN_AGE=3600,
TIMELINE_CREATE=no and EMPTY_PRE_POST_CLEANUP=yes.
Only four ordinary snapshots are subject to `number` retention, with
a one-hour minimum age; manual snapshots with blank Cleanup remain protected,
up to three curated manually. No snapshot deletion occurs at installation.

These values must be set in Agama's chrooted **post** script, before the
first reboot, and only verified (never re-applied) in the one-time **init**
script. Test a real VM install: a shell self-test does NOT prove that Agama
has already created /etc/snapper/configs/root at post-script time.
If that file is missing, installation must report a clear error rather
than silently claim retention is configured. Agama storage stays interactive.

## Bootloader parameter regression

Boot the Agama ISO using its **normal** entry. On x86_64, YaST may copy
failsafe parameters from the live ISO after Agama's post/chroot scripts.
The installer profile adds `security=apparmor` in the normal case.
The firstboot script sanitizes `/etc/kernel/cmdline` and invokes the
installed system's `sdbootutil update-all-entries` only when necessary.
It does not edit the EFI filesystem directly or select/change partitions.

After the first normal boot check `/proc/cmdline`, `/etc/kernel/cmdline`,
`systemctl is-active sddm` and `sudo aa-status`. No standalone `3`,
`nomodeset`, or empty `security=` may remain in the saved configuration.
Booting the installer ISO in failsafe may leave the **first** installed boot
in text mode; the firstboot script repairs subsequent boot entries, and
the next boot is graphical. It does not force Wayland under `nomodeset`.

Confirm YaST launches from the Plasma menu with `xauth` installed.

## Service policy acceptance (2026-10-09)

The next fresh installation must retain `NetworkManager.service`,
`bluetooth.service`, `cups.service`, `chronyd.service`,
`firewalld.service`, and `snapper-cleanup.timer`. Both wireless
radios start off; the user can turn them on from Plasma later without
a recurrent script turning them back off. Read:
`nmcli radio wifi`, `bluetoothctl show`, and
`systemctl is-enabled bluetooth.service NetworkManager.service`.

Check the three disabled btrfsmaintenance timers plus monthly scrub and
weekly `fstrim.timer` using `systemctl list-timers --all` and
`/etc/sysconfig/btrfsmaintenance`. Check mdcheck and NVMe-oF units with
`systemctl is-enabled`; they are disabled, NOT masked or uninstalled.
Never run mdadm/LVM removal in the service phase.

Back In Time remains available via the application menu and starts only
manually. On a fresh user home verify both
`/etc/xdg/autostart/backintime.desktop` and
`~/.config/autostart/backintime.desktop` have `Hidden=true`,
and `systemctl --user --failed` has no new backintime autostart failure.
When reusing an existing home, an old user autostart file can override
system policy: verify it explicitly. Do not claim this acceptance passed
until tested on the actual installation/VM.

The RAID/LVM and NVMe-oF service-disable decisions are applied only on
first boot after successful detection of the installed disk layout; presets
must NOT unconditionally override an Agama user-selected storage scheme.
