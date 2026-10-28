#!/usr/bin/env python3
"""Synchronize assets and generate offline profile for Agama KIWI installer.

Copies all policy files, scripts, and keys into root/usr/share/myslowroll/
and transforms profile-final.jsonnet to reference local file:/// URLs.
"""
import json
import os
import pathlib
import shutil
import sys

def main():
    script_dir = pathlib.Path(__file__).resolve().parent
    repo_root = script_dir.parents[1]
    overlay_dir = script_dir / "root" / "usr" / "share" / "myslowroll"

    # 1. Load source policy and final profile
    policy_path = repo_root / "agama" / "profile-policy.json"
    profile_path = repo_root / "agama" / "profile-final.jsonnet"
    if not policy_path.is_file() or not profile_path.is_file():
        print(f"ERROR: Missing {policy_path} or {profile_path}", file=sys.stderr)
        return 1

    policy = json.loads(policy_path.read_text())
    profile = json.loads(profile_path.read_text())

    # Collect all assets
    assets = [entry["source"] for entry in policy["files"]]
    for scripts in policy["scripts"].values():
        assets.extend(entry["source"] for entry in scripts)

    # 2. Create clean overlay structure
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
        # Ensure executable for scripts
        if src.suffix == ".sh":
            dst.chmod(0o755)
        else:
            dst.chmod(0o644)
        copied += 1

    # 3. Transform profile URLs from raw.githubusercontent.com to file:///usr/share/myslowroll/
    offline_profile = json.loads(profile_path.read_text())
    
    # Process files entries
    for entry in offline_profile.get("files", []):
        url = entry.get("url", "")
        if "raw.githubusercontent.com" in url:
            # Extract relative path after repo revision
            # Format: https://raw.githubusercontent.com/krism-eu/mySlowrollOS/<rev>/<path>
            parts = url.split("raw.githubusercontent.com/krism-eu/mySlowrollOS/")[1].split("/", 1)
            rel_path = parts[1]
            entry["url"] = f"file:///usr/share/myslowroll/{rel_path}"

    # Process scripts entries
    for kind, scripts in offline_profile.get("scripts", {}).items():
        for script in scripts:
            url = script.get("url", "")
            if "raw.githubusercontent.com" in url:
                parts = url.split("raw.githubusercontent.com/krism-eu/mySlowrollOS/")[1].split("/", 1)
                rel_path = parts[1]
                script["url"] = f"file:///usr/share/myslowroll/{rel_path}"

    # 4. Write offline profile
    dst_profile = overlay_dir / "profile-final.jsonnet"
    content = json.dumps(offline_profile, indent=2) + "\n"
    dst_profile.write_text(content)
    dst_profile.chmod(0o644)

    # 5. Verify zero GitHub URLs and all local file references exist
    if "raw.githubusercontent.com" in content:
        print("ERROR: Remote GitHub URLs still present in offline profile!", file=sys.stderr)
        return 1

    missing_local = 0
    for entry in offline_profile.get("files", []):
        url = entry.get("url", "")
        if url.startswith("file:///usr/share/myslowroll/"):
            local_rel = url[len("file:///usr/share/myslowroll/"):]
            if not (overlay_dir / local_rel).is_file():
                print(f"ERROR: Referenced file missing in overlay: {local_rel}", file=sys.stderr)
                missing_local += 1

    for kind, scripts in offline_profile.get("scripts", {}).items():
        for script in scripts:
            url = script.get("url", "")
            if url.startswith("file:///usr/share/myslowroll/"):
                local_rel = url[len("file:///usr/share/myslowroll/"):]
                if not (overlay_dir / local_rel).is_file():
                    print(f"ERROR: Referenced script missing in overlay: {local_rel}", file=sys.stderr)
                    missing_local += 1

    if missing_local > 0:
        return 1

    print(f"PASS: {copied} assets copied to root/usr/share/myslowroll/")
    print("PASS: Offline profile generated at root/usr/share/myslowroll/profile-final.jsonnet (zero GitHub URLs, 100% local references validated)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
