#!/bin/bash
# ==============================================================================
# config.sh - Post-install live system configuration for Agama Installer ISO
# Executed by KIWI inside the chroot environment before packing the image.
# ==============================================================================

test -f /.kconfig && . /.kconfig
test -f /.profile && . /.profile

set -euo pipefail

echo "=== [mySlowrollOS] Configurazione live image Agama Installer ==="

# 1. Abilitazione servizi essenziali per il live installer
systemctl enable NetworkManager.service 2>/dev/null || true
systemctl enable dbus.service 2>/dev/null || true

# Abilitazione servizi Agama se presenti
for srv in agama.service agama-web-server.service cockpit.service; do
    if systemctl list-unit-files "$srv" &>/dev/null; then
        echo "Abilitazione servizio: $srv"
        systemctl enable "$srv" 2>/dev/null || true
    fi
done

# 2. Verifica profilo e asset mySlowrollOS (inclusione di config.sh.delta)
PROFILE_PATH="/usr/share/myslowroll/profile-final.jsonnet"

if [ ! -f "${PROFILE_PATH}" ]; then
    echo "ERRORE: Profilo mySlowrollOS non trovato in ${PROFILE_PATH}" >&2
    echo "Assicurarsi che root/usr/share/myslowroll/profile-final.jsonnet sia presente nell'albero della recipe." >&2
    exit 1
fi

# Imposta permessi corretti per il file del profilo
chmod 0644 "${PROFILE_PATH}"
chown root:root "${PROFILE_PATH}"

# Controllo anti-dipendenze esterne: la ISO deve essere 100% autonoma
if grep -q "raw.githubusercontent.com" "${PROFILE_PATH}"; then
    echo "ERRORE CRITICO: Trovati URL remoti verso raw.githubusercontent.com in ${PROFILE_PATH}!" >&2
    echo "La build offline della ISO richiede che tutte le policy siano pacchettizzate in RPM o locali." >&2
    exit 1
fi

echo "=== [mySlowrollOS] Profilo verificato con successo (autonomo, zero URL GitHub) ==="
exit 0
