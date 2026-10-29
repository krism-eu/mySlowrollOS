#!/bin/bash
# ==============================================================================
# wait-for-agama.sh - Attende l'avvio del server HTTP/HTTPS di Agama prima di avviare Firefox
# ==============================================================================
set -euo pipefail

# 0. Garantisce password root impostata a runtime nel sistema live
echo "root:root" | chpasswd 2>/dev/null || true

echo "mySlowrollOS Kiosk: attesa disponibilità del server Agama su localhost..."

for i in {1..120}; do
    if curl -s -k -f -o /dev/null -m 1 https://localhost/ || curl -s -k -f -o /dev/null -m 1 https://127.0.0.1/ || curl -s -f -o /dev/null -m 1 http://localhost/ || curl -s -f -o /dev/null -m 1 http://127.0.0.1/; then
        echo "mySlowrollOS Kiosk: server Agama pronto su localhost (tentativo $i)."
        echo "root" | agama auth login 2>/dev/null || true

        # La configurazione viene caricata automaticamente da agama-cmdline-process
        # (sshim) e successivamente da agama-autoinstall; NON bloccare qui: altrimenti
        # l'unità kiosk supera il timeout di systemd (90s) mentre l'installer fila
        # l'interfaccia interattiva, cage non parte e si ottiene uno schermo nero.
        # Il caricamento manuale qui sotto è solo diagnostico (non bloccante).
        if [ -f "/autoinst.json" ]; then
            echo "mySlowrollOS Kiosk: configurazione profilo in /autoinst.json (caricata da agama-autoinstall)"
        fi

        exit 0
    fi
    sleep 1
done

echo "mySlowrollOS Kiosk: avvio Firefox in kiosk mode..."
exit 0
