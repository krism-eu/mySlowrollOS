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

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = "https://raw.githubusercontent.com/krism-eu/mySlowrollOS/"
PIN = ROOT / "agama/assets-revision"


def generate(revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("assets revision must be a full 40-character commit SHA")
    manifest = (ROOT / "myslowroll-workstation/myslowroll-workstation.spec").read_text()
    packages = re.findall(r"^Requires:\s+(\S+)\s*$", manifest, re.MULTILINE)
    if not packages or len(packages) != len(set(packages)):
        raise ValueError("empty or duplicate package manifest")
    profile = json.loads((ROOT / "agama/profile-policy.json").read_text())
    if any(key in profile for key in ("storage", "user", "root")):
        raise ValueError("storage and authentication must remain interactive")
    profile["software"]["packages"] = sorted(packages)
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
