# Architecture decision — 2026-10-07

Goal: finish mySlowrollOS without restarting the design.

## Active baseline
Use the recovered late-September sources and the current OBS criscore1 0.2 package as the authoritative baseline.
Older early-September seeds/specs are historical reference only and must not be merged into the active package lists.

## Installation path
Agama remains the primary installer.
The installation must remain interactive: no unattended `inst.auto` flow.
The remote configuration is kept in GitHub and loaded for review before installation.

## Responsibilities
- `criscore1/criscore2`: protected core anchors published in OBS.
- `atomic-update`: separate OBS package; keep current package until the updater redesign is explicitly decided.
- `myslowroll-workstation`: full workstation manifest.
- `myslowroll-policy`: persistent static policy.
- `agama/post-install.sh`: stateful post-install operations that are inappropriate or unreliable as static files.
- `agama-product-myslowroll`: Agama product definition and storage/software defaults.

## Repository and GPG
OBS repository:
`https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/`

Trusted key fingerprint:
`85283DD3E1AFA9EA668E20653505E29C78A00759`

The public key is stored at `agama/keys/home_krism.asc`.
Do not solve GPG errors by globally disabling signature checks.

## Immediate completion sequence
1. Validate the recovered package manifests and policy as-is; only fix concrete errors.
2. Build a minimal Agama remote-profile test for product + OBS repository + GPG + criscore package resolution.
3. Only after that succeeds, integrate storage and post-install.
4. Validate with `agama config generate/load/show` without starting installation.
5. Test the complete profile in a VM.
6. Install on hardware only after the VM result is reproducible.

Do not reintroduce older seed splits unless a current file or a concrete failure proves they are needed.
