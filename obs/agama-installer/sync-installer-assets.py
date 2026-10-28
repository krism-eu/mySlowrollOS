#!/usr/bin/env python3
"""Synchronize assets and generate offline profile for Agama KIWI installer.

Copies all policy files, scripts, and keys into root/usr/share/myslowroll/
and transforms profile-final.jsonnet to reference local file:/// URLs.
Supports --check mode for CI without modifying files on disk.
"""
import argparse
import json
import os
import pathlib
import shutil
import stat
import sys


def compute_offline_profile(profile_path):
    offline_profile = json.loads(profile_path.read_text())

    for entry in offline_profile.get("files", []):
        url = entry.get("url", "")
        if "raw.githubusercontent.com" in url:
            parts = url.split("raw.githubusercontent.com/krism-eu/mySlowrollOS/")[1].split("/", 1)
            rel_path = parts[1]
            entry["url"] = f"file:///usr/share/myslowroll/{rel_path}"

    for kind, scripts in offline_profile.get("scripts", {}).items():
        for script in scripts:
            url = script.get("url", "")
            if "raw.githubusercontent.com" in url:
                parts = url.split("raw.githubusercontent.com/krism-eu/mySlowrollOS/")[1].split("/", 1)
                rel_path = parts[1]
                script["url"] = f"file:///usr/share/myslowroll/{rel_path}"

    return json.dumps(offline_profile, indent=2) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if overlay assets or profile drift from repository")
    args = parser.parse_args()

    script_dir = pathlib.Path(__file__).resolve().parent
    repo_root = script_dir.parents[1]
    overlay_dir = script_dir / "root" / "usr" / "share" / "myslowroll"

    policy_path = repo_root / "agama" / "profile-policy.json"
    profile_path = repo_root / "agama" / "profile-final.jsonnet"
    if not policy_path.is_file() or not profile_path.is_file():
        print(f"ERROR: Missing {policy_path} or {profile_path}", file=sys.stderr)
        return 1

    policy = json.loads(policy_path.read_text())

    assets = [entry["source"] for entry in policy["files"]]
    for scripts in policy["scripts"].values():
        assets.extend(entry["source"] for entry in scripts)

    expected_profile_content = compute_offline_profile(profile_path)

    if args.check:
        stale = []
        if not overlay_dir.is_dir():
            print(f"ERROR: Overlay directory missing: {overlay_dir}", file=sys.stderr)
            return 1

        for rel_path in assets:
            src = repo_root / rel_path
            dst = overlay_dir / rel_path
            if not dst.is_file():
                stale.append(f"missing asset: {rel_path}")
                continue
            if src.read_bytes() != dst.read_bytes():
                stale.append(f"content mismatch: {rel_path}")
                continue
            expected_mode = 0o755 if src.suffix == ".sh" else 0o644
            actual_mode = stat.S_IMODE(dst.stat().st_mode)
            if actual_mode != expected_mode:
                stale.append(f"permission mismatch: {rel_path} ({oct(actual_mode)} != {oct(expected_mode)})")

        dst_profile = overlay_dir / "profile-final.jsonnet"
        if not dst_profile.is_file():
            stale.append("missing profile: profile-final.jsonnet")
        elif dst_profile.read_text() != expected_profile_content:
            stale.append("content mismatch: profile-final.jsonnet")

        if stale:
            print("ERROR: Out-of-date or drifted overlay assets in root/usr/share/myslowroll/:", file=sys.stderr)
            for err in stale:
                print(f"  - {err}", file=sys.stderr)
            return 1

        print(f"PASS: {len(assets)} assets and offline profile match repository sources")
        return 0

    # Write / sync mode
    if overlay_dir.exists():
        shutil.rmtree(overlay_dir)
    overlay_dir.mkdir(parents=True, exist_ok=True)

    copied = 0
    for rel_path in assets:
        src = repo_root / rel_path
        dst = overlay_dir / rel_path
        if not src.is_file():
            print(f"ERROR: Source asset not found: {src}", file=sys.stderr)
            return 1
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        if src.suffix == ".sh":
            dst.chmod(0o755)
        else:
            dst.chmod(0o644)
        copied += 1

    dst_profile = overlay_dir / "profile-final.jsonnet"
    dst_profile.write_text(expected_profile_content)
    dst_profile.chmod(0o644)

    # Self-validation
    if "raw.githubusercontent.com" in expected_profile_content:
        print("ERROR: Remote GitHub URLs still present in offline profile!", file=sys.stderr)
        return 1

    offline_data = json.loads(expected_profile_content)
    for entry in offline_data.get("files", []):
        url = entry.get("url", "")
        if url.startswith("file:///usr/share/myslowroll/"):
            local_rel = url[len("file:///usr/share/myslowroll/"):]
            if not (overlay_dir / local_rel).is_file():
                print(f"ERROR: Referenced file missing in overlay: {local_rel}", file=sys.stderr)
                return 1

    for kind, scripts in offline_data.get("scripts", {}).items():
        for script in scripts:
            url = script.get("url", "")
            if url.startswith("file:///usr/share/myslowroll/"):
                local_rel = url[len("file:///usr/share/myslowroll/"):]
                if not (overlay_dir / local_rel).is_file():
                    print(f"ERROR: Referenced script missing in overlay: {local_rel}", file=sys.stderr)
                    return 1

    print(f"PASS: {copied} assets copied to root/usr/share/myslowroll/")
    print("PASS: Offline profile generated at root/usr/share/myslowroll/profile-final.jsonnet (zero GitHub URLs, 100% local references validated)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
