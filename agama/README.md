# Agama installation path

The first mySlowrollOS installer path deliberately reuses the official Agama Live ISO instead of rebuilding an installer ISO.

The project profile is intentionally partial:

- product: `Slowroll`;
- no desktop or distribution patterns (`patterns: []`);
- explicit packages generated from `experiments/rootfs/workstation.seed` plus `criscore1` and `criscore2`;
- `onlyRequired: true`;
- one OBS repository containing the signed criscore RPMs;
- no `storage` section;
- no users or passwords.

Omitting storage is deliberate. The profile is loaded with `inst.install=0`, so Agama applies the software/product choices and then stops for review. Storage is completed manually in the Agama UI, including reuse of an existing `/home` without formatting.

## Generate the profile

After the OBS Slowroll repository for criscore is published:

```sh
bash agama/generate-workstation-profile \
  https://download.opensuse.org/repositories/home:USER/openSUSE_Slowroll/
```

Commit the resulting `agama/workstation.jsonnet`. During development the raw GitHub URL can then be used with `inst.auto`; after merge, prefer the `main` URL.

## Boot Agama

Use the official Agama Live ISO and add these kernel parameters to the installer entry:

```text
inst.auto=PROFILE_URL inst.install=0 inst.systemd_boot_preview=1
```

`inst.install=0` is mandatory for this project path: the machine must stop for review instead of immediately installing. `inst.systemd_boot_preview=1` enables Agama's current systemd-boot path; installation testing must verify that Agama did not fall back to GRUB.

## ISO policy

Do not build a custom ISO for the first installation tests. If the remote-profile flow is validated and an offline/single-medium installer becomes useful later, inject the same profile into an official Agama ISO instead of maintaining a fork of the installer image.
