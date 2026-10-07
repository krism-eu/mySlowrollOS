# Architecture decision — 2026-10-07

Goal: finish mySlowrollOS without restarting the design.

## Active source of truth
- Late-September recovered sources are the active historical baseline.
- Current OBS `criscore1` 0.2 is authoritative for the protected core.
- Earlier September seeds/specs are reference material only and are not merged into the active lists.

## Installation path
Agama 24 with the stock `Slowroll` product is the primary installer.
The installation remains interactive. Do not use unattended `inst.auto` for the hardware install.
The remote profile in GitHub supplies software/repository policy and is loaded for review before installation.

A custom `agama-product-myslowroll` package is retained as recovered reference, but it is not required by the current stock-Agama workflow and must not be added to OBS merely to make this path work.

## Software composition
- `agama/profile-software-final.json` is the active explicit workstation package profile.
- `criscore1/criscore2` are protected core anchors from OBS.
- `atomic-update` remains an OBS package for the current baseline.
- `myslowroll-workstation` is retained as the human/RPM manifest source used to audit the explicit package list; it is not required to exist in OBS for the current Agama path.
- `myslowroll-policy` is retained as the policy source; its settings will be deployed by Agama files/scripts instead of assuming an OBS RPM.

## OBS repository and trust
Repository:
`https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/`

Trusted fingerprint:
`85283DD3E1AFA9EA668E20653505E29C78A00759`

Public key:
`agama/keys/home_krism.asc`

Never disable signature checking to work around trust failures.

## Verified on Agama 24 Build11.3
- remote profile generation/validation/load works;
- target repo `home_krism` is created;
- target solver indexes `criscore1` and `criscore2` 0.2-1.1;
- target solver selects `atomic-update` 5.6.1-6.1 and both criscore anchors;
- full software profile reaches `Ready to start the installation`;
- Agama reports no issues/questions and libsolv reports 0 problems / 0 unsolvable;
- recovered post-install script passes `bash -n`.

## Remaining work
1. Convert static policy into Agama `files` entries where appropriate.
2. Move operations that require a running systemd from post-chroot to an Agama `init` script.
3. Finalize storage for the actual hardware interactively/profile-assisted.
4. Test systemd-boot with the Agama systemd-boot preview enabled if required by the media/product.
5. Perform one complete VM installation before hardware installation.
