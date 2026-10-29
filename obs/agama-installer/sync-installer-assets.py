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
import tarfile


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


def pack_root_archive(script_dir):
    root_dir = script_dir / "root"
    archive_path = script_dir / "root.tar.gz"

    with tarfile.open(archive_path, "w:gz") as tar:
        for dirpath, dirs, files in os.walk(root_dir):
            dirs.sort()
            files.sort()
            for d in dirs:
                full_path = os.path.join(dirpath, d)
                rel_path = os.path.relpath(full_path, root_dir)
                info = tar.gettarinfo(full_path, arcname=rel_path)
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "root"
                info.mode = 0o755
                tar.addfile(info)
            for f in files:
                full_path = os.path.join(dirpath, f)
                rel_path = os.path.relpath(full_path, root_dir)
                info = tar.gettarinfo(full_path, arcname=rel_path)
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "root"
                if os.path.islink(full_path):
                    info.type = tarfile.SYMTYPE
                    info.linkname = os.readlink(full_path)
                    tar.addfile(info)
                else:
                    if os.access(full_path, os.X_OK):
                        info.mode = 0o755
                    else:
                        info.mode = 0o644
                    with open(full_path, "rb") as fp:
                        tar.addfile(info, fp)
    return archive_path


def verify_root_archive(archive_path):
    if not archive_path.is_file():
        return ["root.tar.gz mancante"]
    errors = []
    try:
        with tarfile.open(archive_path, "r:gz") as tar:
            names = tar.getnames()
            bad = [n for n in names if n.startswith("root/") or n.startswith("/") or n.startswith("./")]
            if bad:
                errors.append(f"root.tar.gz contiene prefissi non validi ({bad[:3]}...)")
            required = [
                "autoinst.json",
                "usr/share/myslowroll/profile-final.json",
                "usr/lib/systemd/system/agama-kiosk.service",
                "usr/libexec/myslowroll/wait-for-agama.sh",
                "etc/firefox/policies/policies.json",
                "usr/lib/firefox/distribution/policies.json",
            ]
            for req in required:
                if req not in names:
                    errors.append(f"root.tar.gz non contiene il file essenziale: {req}")
    except Exception as e:
        errors.append(f"Impossibile leggere root.tar.gz: {e}")
    return errors


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

        dst_profile = overlay_dir / "profile-final.json"
        if not dst_profile.is_file():
            stale.append("missing profile: profile-final.json")
        elif dst_profile.read_text() != expected_profile_content:
            stale.append("content mismatch: profile-final.json")

        # Verify Kiosk systemd unit and launcher script
        kiosk_service = script_dir / "root" / "usr" / "lib" / "systemd" / "system" / "agama-kiosk.service"
        if not kiosk_service.is_file():
            stale.append("missing kiosk unit: root/usr/lib/systemd/system/agama-kiosk.service")
        else:
            kiosk_text = kiosk_service.read_text()
            if "WLR_LIBINPUT_NO_DEVICES" in kiosk_text:
                stale.append("kiosk unit contains obsolete WLR_LIBINPUT_NO_DEVICES directive (breaks mouse/keyboard!)")
            if "--private-window" in kiosk_text:
                stale.append("kiosk unit contains --private-window (breaks Firefox token/certs persistence!)")
            if "https://localhost/" not in kiosk_text:
                stale.append("kiosk unit does not use https://localhost/")

        kiosk_wait = script_dir / "root" / "usr" / "libexec" / "myslowroll" / "wait-for-agama.sh"
        if not kiosk_wait.is_file():
            stale.append("missing kiosk launcher: root/usr/libexec/myslowroll/wait-for-agama.sh")
        elif not os.access(kiosk_wait, os.X_OK):
            stale.append("kiosk launcher not executable: root/usr/libexec/myslowroll/wait-for-agama.sh")

        # Verify Firefox Enterprise Policies
        ff_policy = script_dir / "root" / "etc" / "firefox" / "policies" / "policies.json"
        if not ff_policy.is_file():
            stale.append("missing firefox policy: root/etc/firefox/policies/policies.json")

        # Verify root.tar.gz archive
        archive_path = script_dir / "root.tar.gz"
        archive_errors = verify_root_archive(archive_path)
        stale.extend(archive_errors)

        if stale:
            print("ERROR: Out-of-date or drifted overlay assets in root/usr/share/myslowroll/:", file=sys.stderr)
            for err in stale:
                print(f"  - {err}", file=sys.stderr)
            return 1

        print(f"PASS: {len(assets)} assets and offline profile match repository sources")
        print(f"PASS: root.tar.gz verificato con successo (nessun prefisso non valido, tutti i file essenziali inclusi)")
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

    dst_profile = overlay_dir / "profile-final.json"
    dst_profile.write_text(expected_profile_content)
    dst_profile.chmod(0o644)

    dst_profile_legacy = overlay_dir / "profile-final.jsonnet"
    if dst_profile_legacy.is_symlink() or dst_profile_legacy.is_file():
        dst_profile_legacy.unlink()
    dst_profile_legacy.symlink_to("profile-final.json")

    # Scrive autoinst.json e autoinst.jsonnet alla root dell'overlay per agama-autoinstall
    root_autoinst = script_dir / "root" / "autoinst.json"
    root_autoinst.write_text(expected_profile_content)
    root_autoinst.chmod(0o644)

    root_autoinst_legacy = script_dir / "root" / "autoinst.jsonnet"
    if root_autoinst_legacy.is_symlink() or root_autoinst_legacy.is_file():
        root_autoinst_legacy.unlink()
    root_autoinst_legacy.symlink_to("autoinst.json")

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
    print("PASS: Offline profile generated at root/usr/share/myslowroll/profile-final.json (zero GitHub URLs, 100% local references validated)")

    # Pacchettizzazione root.tar.gz per OBS (con path relativi 'usr/...' senza prefisso 'root/')
    arch_file = pack_root_archive(script_dir)
    arch_errors = verify_root_archive(arch_file)
    if arch_errors:
        print(f"ERROR: Verifica archivio {arch_file} fallita:", file=sys.stderr)
        for err in arch_errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    print(f"PASS: {arch_file.name} impacchettato e verificato con successo per OBS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
