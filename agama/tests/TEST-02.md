# Test 02 — actual final profile

Run from a checkout/archive of the reviewed commit in an Agama 24 live VM:

```sh
bash agama/tests/run-test02.sh
```

The runner uses profile-final.jsonnet directly. The retained
02-full-vm-validation.jsonnet is generated identically, including the repository
key, post-chroot SDDM selector, init script and zram configuration.
The audit loads/probes configuration but never calls agama install.
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
