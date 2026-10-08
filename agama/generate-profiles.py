#!/usr/bin/env python3
"""Generate self-contained Agama profiles from the RPM manifest and policy.

JSON output is valid Jsonnet and needs no remote imports.
The test profile is byte-identical to production.
"""
import argparse
import copy
import json
import pathlib
import re
import sys
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = "https://raw.githubusercontent.com/krism-eu/mySlowrollOS/"
PIN = ROOT / "agama/assets-revision"


def generate(revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("assets revision must be a full 40-character commit SHA")
    # Reject stale or manually edited protected anchor specs.
    subprocess.run([sys.executable, str(ROOT / "core/generate-criscore-spec.py"),
                    "--check"], check=True)
    manifest = (ROOT / "myslowroll-workstation/myslowroll-workstation.spec").read_text()
    persistent = re.findall(r"^Requires:\s+(\S+)\s*$", manifest, re.MULTILINE)
    if not persistent or len(persistent) != len(set(persistent)):
        raise ValueError("empty or duplicate persistent package manifest")

    # Installation-only packages are chosen by Agama but must NEVER become
    # hard dependencies of the workstation RPM or either protected anchor.
    lines = (ROOT / "agama/install-only-packages.txt").read_text().splitlines()
    install_only = [line.strip() for line in lines
                    if line.strip() and not line.lstrip().startswith("#")]
    if not install_only or len(install_only) != len(set(install_only)):
        raise ValueError("empty or duplicate install-only package list")
    if any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.+-]*", pkg)
           for pkg in install_only):
        raise ValueError("invalid install-only package name")
    if overlap := set(persistent) & set(install_only):
        raise ValueError("install-only packages are RPM requirements: "
                         + ", ".join(sorted(overlap)))

    core_spec = (ROOT / "obs/criscore1/criscore1.spec").read_text()
    core_requires = re.findall(r"^Requires:\s+(\S+)\s*$", core_spec, re.MULTILINE)
    halfway = len(core_requires) // 2
    if not core_requires or len(core_requires) % 2 or (
            core_requires[:halfway] != core_requires[halfway:]):
        raise ValueError("criscore1 and criscore2 Requires must match")
    if missing := set(core_requires[:halfway]) - set(persistent):
        raise ValueError("protected packages missing from persistent manifest: "
                         + ", ".join(sorted(missing)))
    # Agama must install the metapackage for persistent requirements to matter
    # on later RPM upgrades, not merely install individual packages today.
    workstation = "myslowroll-workstation"
    if workstation in persistent or workstation in install_only:
        raise ValueError("workstation metapackage must be specified only here")

    profile = json.loads((ROOT / "agama/profile-policy.json").read_text())
    if any(key in profile for key in ("storage", "user", "root")):
        raise ValueError("storage and authentication must remain interactive")
    profile["software"]["packages"] = sorted(persistent + install_only + [workstation])
    entries = list(profile["files"])
    for scripts in profile["scripts"].values():
        entries.extend(scripts)
    for entry in entries:
        source = entry.pop("source")
        if source.startswith("/") or ".." in pathlib.PurePosixPath(source).parts:
            raise ValueError(f"invalid asset path: {source}")
        if not (ROOT / source).is_file():
            raise ValueError(f"missing asset: {source}")
        entry["url"] = BASE + revision + "/" + source
    software = {"product": profile["product"], "software": profile["software"]}
    return {
        "agama/profile-final.jsonnet": profile,
        "agama/tests/02-full-vm-validation.jsonnet": copy.deepcopy(profile),
        "agama/profile-software-final.json": software,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets-revision", help="commit containing reviewed policy files/scripts")
    parser.add_argument("--check", action="store_true", help="fail on generated-file drift")
    args = parser.parse_args()
    revision = args.assets_revision or PIN.read_text().strip()
    stale = []
    for name, value in generate(revision).items():
        content = json.dumps(value, indent=2) + "\n"
        path = ROOT / name
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(name)
        else:
            path.write_text(content)
    if args.check:
        if not PIN.exists() or PIN.read_text() != revision + "\n":
            stale.append("agama/assets-revision")
        if stale:
            print("Out-of-date generated files: " + ", ".join(stale), file=sys.stderr)
            return 1
        print("PASS: profiles match manifest/policy; final and test02 are identical")
    else:
        PIN.write_text(revision + "\n")
        print(f"Generated profiles pinned to {revision}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
