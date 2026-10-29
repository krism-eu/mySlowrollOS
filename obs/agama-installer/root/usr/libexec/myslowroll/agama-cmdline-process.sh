#!/bin/bash
# ==============================================================================
# agama-cmdline-process.sh - Scrive /run/agama/cmdline.d/{agama,kernel}.conf
#
# Riproduce il servizio upstream agama-cmdline-process che nelle ISO live
# ufficiali Agama viene fornito dall'initrd, ma che nelle immagini live
# costruite con KIWI non esiste: senza questi file agama-autoinstall non
# riesce a leggere le opzioni di boot (inst.auto=..., inst.install=0) e
# termina con "Could not read cmdline args file" prima di caricare il profilo.
# ==============================================================================
set -euo pipefail

CMDLINE_DIR="/run/agama/cmdline.d"
mkdir -p -m 0755 "${CMDLINE_DIR}"

# Command line kernel completo, un parametro per riga
tr ' ' '\n' < /proc/cmdline | sed '/^$/d' > "${CMDLINE_DIR}/kernel.conf"
chmod 0644 "${CMDLINE_DIR}/kernel.conf"

# Sottoinsieme rilevante per lo stack installer (inst.*, live.*, agama*)
AGAMA_CONF="${CMDLINE_DIR}/agama.conf"
tr ' ' '\n' < /proc/cmdline | sed '/^$/d' | grep -E '^(inst\.|live\.|agama)' \
    > "${AGAMA_CONF}" || true
chmod 0644 "${AGAMA_CONF}"

echo "agama-cmdline-process: scritti ${AGAMA_CONF} e ${CMDLINE_DIR}/kernel.conf"
