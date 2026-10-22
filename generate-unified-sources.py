#!/usr/bin/env python3
"""
generate-unified-sources.py
Generatore deterministico del file unificato dei sorgenti per MSCC (mySlowrollOS Control Center).
Sovrascrive sempre completamente il file di destinazione (nessun accodamento).
"""

from datetime import date
import os
import re
import sys

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))

def get_project_version():
    cmake_path = os.path.join(PROJECT_ROOT, "CMakeLists.txt")
    if os.path.isfile(cmake_path):
        with open(cmake_path, "r", encoding="utf-8") as f:
            match = re.search(r"project\s*\(\s*myslowroll-cc\s+VERSION\s+([0-9\.]+)", f.read(), re.IGNORECASE)
            if match:
                return match.group(1)
    return "1.0.0"

VERSION = get_project_version()
TODAY_ISO = date.today().isoformat()
ARTIFACT_PATH = os.environ.get("MSCC_ARTIFACT_PATH")
OUTPUT_LOCAL = os.path.join(PROJECT_ROOT, "myslowroll-cc-sorgenti-unificati.txt")

FILES_TO_INCLUDE = [
    "CMakeLists.txt",
    "build-rpm.sh",
    "packaging/myslowroll-cc.spec",
    "packaging/myslowroll-cc.changes",
    "packaging/myslowroll-cc-rpmlintrc",
    ".github/workflows/ci.yml",
    ".gitignore",
    "LICENSE",
    "README.md",
    "data/myslowroll-cc.desktop",
    "data/org.myslowrollos.controlcenter.policy",
    "data/org.myslowrollos.controlcenter.metainfo.xml",
    "data/icons/hicolor/scalable/apps/myslowroll-cc.svg",
    "generate-unified-sources.py",
    "src/main.cpp",
    "src/DesktopBackend.h",
    "src/DesktopBackend.cpp",
    "src/SlowrollBackend.h",
    "src/SlowrollBackend.cpp",
    "tests/test_domain.cpp",
    "qml/Main.qml",
    "qml/components/UiMetrics.qml",
    "qml/components/StatCard.qml",
    "qml/components/OutputCard.qml",
    "qml/modules/DashboardModule.qml",
    "qml/modules/SoftwareModule.qml",
    "qml/modules/ServicesNetworkModule.qml",
    "qml/modules/SystemModule.qml",
    "qml/modules/RecoveryModule.qml",
    "qml/modules/CommandsModule.qml",
    "qml/modules/ToolsModule.qml",
    "data/scripts/mic.sh",
    "data/scripts/privacy.sh",
]

HEADER = f"""================================================================================
MSCC (mySlowrollOS Control Center / myslowroll-cc) - SORGENTI UNIFICATI COMPLETI
================================================================================
Nome Applicazione : MSCC (mySlowrollOS Control Center / myslowroll-cc)
Versione Progetto : {VERSION}
Data Esportazione : {TODAY_ISO}
Target Operativo  : openSUSE Slowroll / KDE Plasma 6 / Qt 6.5+ / KF6 Kirigami

--------------------------------------------------------------------------------
1. ARCHITETTURA E COMPONENTI DI SISTEMA
--------------------------------------------------------------------------------
* CONFIGURAZIONE, BUILD & PACKAGING:
  - CMakeLists.txt              : Configurazione C++20, linking Qt6 e KF6 Kirigami,
                                  installazione desktop file, icona, policy PolKit e metainfo.
  - build-rpm.sh                : Script di build tarball + rpmbuild locale con test e lock.
  - packaging/myslowroll-cc.spec: Specfile RPM per openSUSE Slowroll con Requires/Recommends completi.
  - data/org.myslowrollos.controlcenter.policy : Policy PolKit con exec.path per atomic-update, efibootmgr e zypper.
  - data/org.myslowrollos.controlcenter.metainfo.xml : Metadati AppStream validati.
  - data/myslowroll-cc.desktop  : Desktop entry FreeDesktop/KDE.
  - generate-unified-sources.py : Script di esportazione deterministica dei sorgenti.

* BACKEND C++:
  - src/main.cpp                : Bootstrap applicativo con inizializzazione esplicita dei backend.
  - src/DesktopBackend.h/.cpp   : Monitoraggio risorse hardware, profili energetici PowerDevil (AC),
                                  stato Wi-Fi/rfkill, profili di rete IPv4/CIDR/DNS, esecuzione binari
                                  privilegiati solo da percorsi di sistema (/usr/sbin, /usr/bin),
                                  azioni utente e archiviazione file JSON corrotti (.corrupt-<timestamp>).
  - src/SlowrollBackend.h/.cpp  : Stato atomic-update, rilevamento snapshot attivo da mountinfo,
                                  rilevamento /sys/firmware/efi e BootNext UEFI via efibootmgr,
                                  monitoraggio servizi chiave e unità systemd fallite.

* INTERFACCIA QML & TEST:
  - qml/Main.qml                : Shell Kirigami con barra di notifica unificata (l'ultimo messaggio vince).
  - qml/modules/*.qml           : 7 moduli operativi (Dashboard, Software, Servizi/Rete, Sistema/Boot,
                                  Backup/Recovery, Comandi, Strumenti/Fix).
  - tests/test_domain.cpp       : Suite di test unitari QTest/CTest isolata con QTemporaryDir.

===============================================================================
SORGENTI COMPLETI DEL PROGETTO
===============================================================================
"""

def generate():
    output_parts = [HEADER]

    for rel_path in FILES_TO_INCLUDE:
        full_path = os.path.join(PROJECT_ROOT, rel_path)
        if not os.path.isfile(full_path):
            print(f"ATTENZIONE: File non trovato: {rel_path}", file=sys.stderr)
            continue

        with open(full_path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()

        output_parts.append(f"\n{'='*80}\nFILE: {rel_path}\n{'='*80}\n")
        output_parts.append(content)
        if not content.endswith("\n"):
            output_parts.append("\n")

    full_output = "".join(output_parts)

    with open(OUTPUT_LOCAL, "w", encoding="utf-8") as f:
        f.write(full_output)
    print(f"File unificato locale generato: {OUTPUT_LOCAL} ({len(full_output.splitlines())} righe)")

    target_artifact = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else ARTIFACT_PATH
    if target_artifact:
        try:
            artifact_dir = os.path.dirname(target_artifact)
            if artifact_dir:
                os.makedirs(artifact_dir, exist_ok=True)
            with open(target_artifact, "w", encoding="utf-8") as f:
                f.write(full_output)
            print(f"File unificato artefatto sincronizzato: {target_artifact}")
        except OSError as e:
            print(f"Nota: scrittura artefatto omessa ({e})", file=sys.stderr)

if __name__ == "__main__":
    generate()
