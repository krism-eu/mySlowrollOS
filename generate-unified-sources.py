#!/usr/bin/env python3
"""
generate-unified-sources.py
Generatore deterministico del file unificato dei sorgenti per mySlowrollOS (modulo OS).
Genera sia il file sorgente integrale che la versione anonimizzata riproducibile.
Sovrascrive sempre completamente i file di destinazione (nessun accodamento).
"""

from datetime import date
import os
import re
import sys

OS_ROOT = os.path.dirname(os.path.abspath(__file__))
TODAY = date.today().isoformat()
OUT_FILE = os.path.join(OS_ROOT, "mySlowrollOS.txt")
ANON_FILE = os.path.join(OS_ROOT, "mySlowrollOS-anonymized.txt")

FILES_TO_INCLUDE = [
    "README.md",
    "ARCHITECTURE.md",
    "AGENTS.md",
    ".github/skills/slowroll-os-maintenance/SKILL.md",
    ".github/workflows/atomic-update-57-check.yml",
    "core/protected.seed",
    "core/generate-criscore-spec.py",
    "obs/criscore1/criscore1.spec.in",
    "obs/criscore1/criscore1.spec",
    "obs/agama-installer/README.md",
    "obs/agama-installer/agama-installer.kiwi",
    "obs/agama-installer/config.sh",
    "obs/agama-installer/sync-installer-assets.py",
    "obs/agama-installer/test-recipe.sh",
    "myslowroll-workstation/myslowroll-workstation.spec",
    "myslowroll-workstation/myslowroll-workstation.changes",
    "myslowroll-workstation/LICENSE",
    "agama/install-only-packages.txt",
    "agama/profile-policy.json",
    "agama/assets-revision",
    "agama/keys/home_krism.asc",
    "agama/generate-profiles.py",
    "agama/profile-final.jsonnet",
    "agama/post-chroot-boot-policy.sh",
    "agama/init-firstboot.sh",
    "agama/tests/TEST-02.md",
    "agama/tests/run-test02.sh",
    "agama/tests/audit-installed-readonly.sh",
    "atomic-update/5.7-DESIGN.md",
    "atomic-update/atomic-update.spec",
    "atomic-update/atomic-update.changes",
    "atomic-update/myslowroll-update",
    "atomic-update/myslowroll-update.desktop",
    "atomic-update/atomic-update-5.7.1.sh",
    "atomic-update/tests/ci-regression.sh",
    "atomic-update/tests/recovery-review.sh",
    "myslowroll-policy/10-myslowroll.preset",
    "myslowroll-policy/10-myslowroll-wayland.conf",
    "myslowroll-policy/10-myslowroll-zram.conf",
    "myslowroll-policy/10-myslowroll-journald.conf",
    "myslowroll-policy/20-myslowroll-disable-ipv6.conf",
    "myslowroll-policy/90-myslowroll-bluez.conf",
    "myslowroll-policy/90-myslowroll-sddm-fallback.conf",
    "myslowroll-policy/90-myslowroll-sddm-theme.conf",
    "myslowroll-policy/90-myslowroll-zypp.conf",
    "myslowroll-policy/99-myslowroll-passwordless-admin",
    "myslowroll-policy/10-myslowroll-passwordless-admin.rules",
    "myslowroll-policy/home_krism.repo",
    "myslowroll-policy/kcminputrc",
    "myslowroll-policy/kdesurc",
    "myslowroll-policy/kernel-cmdline",
    "myslowroll-policy/NetworkManager.state",
    "myslowroll-policy/backintime-autostart-disabled.desktop",
    "myslowroll-policy/LICENSE",
]

ANONYMIZATION_RULES = [
    (r'-----BEGIN PGP PUBLIC KEY BLOCK-----[\s\S]*?-----END PGP PUBLIC KEY BLOCK-----',
     '-----BEGIN PGP PUBLIC KEY BLOCK-----\n<REDACTED_OBS_PGP_PUBLIC_KEY_BLOCK>\n-----END PGP PUBLIC KEY BLOCK-----', True),
    ('8528 3DD3 E1AF A9EA 668E 2065 3505 E29C 78A0 0759', '<OBS_GPG_FINGERPRINT>', False),
    ('85283DD3E1AFA9EA668E20653505E29C78A00759', '<OBS_GPG_FINGERPRINT_NOSPACES>', False),
    ('c8e17ffbf868d68b7253143874ed2f9d635beda3', '<ASSETS_PINNED_COMMIT_SHA>', False),
    ('https://raw.githubusercontent.com/krism-eu/mySlowrollOS/', 'https://raw.githubusercontent.com/<GITHUB_USER>/mySlowrollOS/', False),
    ('https://github.com/krism-eu/mySlowrollOS', 'https://github.com/<GITHUB_USER>/mySlowrollOS', False),
    ('https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/', 'https://download.opensuse.org/repositories/home:/<OBS_MAINTAINER>/openSUSE_Slowroll/', False),
    ('https://build.opensuse.org/package/show/home:krism/atomic-update', 'https://build.opensuse.org/package/show/home:<OBS_MAINTAINER>/atomic-update', False),
    ('krism@opensuse.org', '<OBS_MAINTAINER>@opensuse.org', False),
    ('kris@opensuse.org', '<AUTHOR_USER>@opensuse.org', False),
    ('kris@myslowrollos.org', '<AUTHOR_USER>@myslowrollos.org', False),
    ('home:krism@build.opensuse.org', 'home:<OBS_MAINTAINER>@build.opensuse.org', False),
    ('krism-eu', '<GITHUB_USER>', False),
    ('home:krism', 'home:<OBS_MAINTAINER>', False),
    ('home_krism', 'home_<OBS_MAINTAINER>', False),
    ('krism', '<OBS_MAINTAINER>', False),
    (r'\bKris\b', '<AUTHOR_USER>', True),
    (r'\bkris\b', '<AUTHOR_USER>', True),
    ('192.168.11.50', '<PRIVATE_STATIC_IP_1>', False),
    ('192.168.11.60', '<PRIVATE_STATIC_IP_2>', False),
    ('192.168.11.1', '<PRIVATE_GATEWAY_IP>', False),
]

def anonymize(text: str) -> str:
    for pat, repl, is_re in ANONYMIZATION_RULES:
        if is_re:
            text = re.sub(pat, repl, text)
        else:
            text = text.replace(pat, repl)
    return text

def generate():
    parts = []
    parts.append("=" * 80 + "\n")
    parts.append("mySlowrollOS - SORGENTI E SPECIFICHE UNIFICATE DEL SISTEMA OPERATIVO BASE\n")
    parts.append("=" * 80 + "\n")
    parts.append(f"Data Esportazione : {TODAY}\n")
    parts.append("Progetto          : mySlowrollOS (openSUSE Slowroll / Plasma Wayland Workstation)\n")
    parts.append("Componente        : Modulo OS / Architettura Base, Policy, Atomic Update, Agama\n\n")

    parts.append("-" * 80 + "\n")
    parts.append("INDICE DEI FILE INCLUSI\n")
    parts.append("-" * 80 + "\n")
    for f in FILES_TO_INCLUDE:
        parts.append(f"  - {f}\n")
    parts.append("\n" + "=" * 80 + "\n\n")

    for rel_path in FILES_TO_INCLUDE:
        full = os.path.join(OS_ROOT, rel_path)
        if os.path.isfile(full):
            parts.append("=" * 80 + "\n")
            parts.append(f"FILE: {rel_path}\n")
            parts.append("=" * 80 + "\n")
            with open(full, "r", encoding="utf-8", errors="replace") as fp:
                content = fp.read()
            parts.append(content)
            if not content.endswith("\n"):
                parts.append("\n")
            parts.append("\n")
        else:
            parts.append(f"FILE NON TROVATO: {rel_path}\n\n")

    out_text = "".join(parts)
    with open(OUT_FILE, "w", encoding="utf-8") as out:
        out.write(out_text)
    print(f"File unificato OS generato: {OUT_FILE} ({len(out_text.splitlines())} righe)")

    anon_text = anonymize(out_text)
    with open(ANON_FILE, "w", encoding="utf-8") as out:
        out.write(anon_text)
    print(f"File unificato OS anonimizzato generato: {ANON_FILE} ({len(anon_text.splitlines())} righe)")

if __name__ == "__main__":
    generate()
