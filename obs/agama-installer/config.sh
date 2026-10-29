#!/bin/bash
# ==============================================================================
# config.sh - Post-install live system configuration for Agama Installer ISO
# Executed by KIWI inside the chroot environment before packing the image.
# ==============================================================================

test -f /.kconfig && . /.kconfig
test -f /.profile && . /.profile

set -euo pipefail

echo "=== [mySlowrollOS] Configurazione live image Agama Installer ==="

# 0. Impostazione password root per ambiente Live (utente: root / password: root)
echo "root:root" | chpasswd

# 1. Preparazione directory e certificati Agama
mkdir -p -m 0755 /etc/agama.d/ssl /run/agama /etc/pki/trust/anchors

if command -v openssl >/dev/null 2>&1; then
    echo "Generazione certificato SSL locale per Agama / Firefox (localhost)..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/agama.d/ssl/server.key \
        -out /etc/agama.d/ssl/server.crt \
        -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,DNS:agama.local,IP:127.0.0.1" 2>/dev/null || true
    chmod 0600 /etc/agama.d/ssl/server.key 2>/dev/null || true
    chmod 0644 /etc/agama.d/ssl/server.crt 2>/dev/null || true
    cp -f /etc/agama.d/ssl/server.crt /etc/pki/trust/anchors/agama-local.crt 2>/dev/null || true
    if command -v update-ca-certificates >/dev/null 2>&1; then
        update-ca-certificates 2>/dev/null || true
    fi
fi

# 2. Abilitazione servizi di rete, bus di sistema e sessioni logind
systemctl enable NetworkManager.service 2>/dev/null || true
systemctl enable dbus.socket 2>/dev/null || true
systemctl enable systemd-logind.service 2>/dev/null || true

# 3. Abilitazione completa stack Agama (D-Bus privato, cmdline, autoinstall e web server)
for srv in \
    agama-dbus-monitor.service \
    agama-proxy-setup.service \
    agama-cmdline-process.service \
    agama.service \
    agama-web-server.service \
    agama-autoinstall.service \
    cockpit.service; do
    if [ -f "/usr/lib/systemd/system/${srv}" ] || [ -f "/etc/systemd/system/${srv}" ]; then
        echo "Abilitazione servizio: ${srv}"
        systemctl enable "${srv}" 2>/dev/null || true
    fi
done

# 3. Configurazione e abilitazione sessione Kiosk grafica locale (Wayland Cage + Firefox)
if [ -f "/usr/lib/systemd/system/agama-kiosk.service" ] || [ -f "/etc/systemd/system/agama-kiosk.service" ]; then
    echo "Abilitazione sessione grafica locale: agama-kiosk.service"
    chmod 0644 /usr/lib/systemd/system/agama-kiosk.service 2>/dev/null || true
    if [ -f "/usr/libexec/myslowroll/wait-for-agama.sh" ]; then
        chmod 0755 /usr/libexec/myslowroll/wait-for-agama.sh
    fi
    systemctl enable agama-kiosk.service 2>/dev/null || true
    systemctl set-default graphical.target 2>/dev/null || true
fi

# 4. Verifica profilo e asset mySlowrollOS (puro JSON per bypassare dipendenza jsonnet)
PROFILE_PATH="/usr/share/myslowroll/profile-final.json"
PROFILE_PATH_LEGACY="/usr/share/myslowroll/profile-final.jsonnet"

if [ ! -f "${PROFILE_PATH}" ]; then
    echo "ERRORE: Profilo mySlowrollOS non trovato in ${PROFILE_PATH}" >&2
    echo "Assicurarsi che root/usr/share/myslowroll/profile-final.json sia presente nell'albero della recipe." >&2
    exit 1
fi

chmod 0644 "${PROFILE_PATH}"
chown root:root "${PROFILE_PATH}"

# Crea symlink di compatibilità .jsonnet -> .json
ln -sf "profile-final.json" "${PROFILE_PATH_LEGACY}"

# Garantisce il profilo alla root per agama-autoinstall (/autoinst.json e /autoinst.jsonnet)
cp -f "${PROFILE_PATH}" /autoinst.json
cp -f "${PROFILE_PATH}" /autoinst.jsonnet
chmod 0644 /autoinst.json /autoinst.jsonnet

# Controllo anti-dipendenze esterne: la ISO deve essere 100% autonoma
if grep -q "raw.githubusercontent.com" "${PROFILE_PATH}"; then
    echo "ERRORE CRITICO: Trovati URL remoti verso raw.githubusercontent.com in ${PROFILE_PATH}!" >&2
    echo "La build offline della ISO richiede che tutte le policy siano pacchettizzate in RPM o locali." >&2
    exit 1
fi

echo "=== [mySlowrollOS] Live image configurata con successo (kiosk attivo, zero URL GitHub) ==="
exit 0
