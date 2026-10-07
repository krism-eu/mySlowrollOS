#!/usr/bin/env bash
set -euo pipefail

PROFILE_URL="${PROFILE_URL:-https://raw.githubusercontent.com/krism-eu/mySlowrollOS/main/agama/personal-software.json}"
PROFILE_FILE="$(mktemp /tmp/myslowroll-agama-profile.XXXXXX.json)"
trap 'rm -f "$PROFILE_FILE"' EXIT

command -v agama >/dev/null 2>&1 || { echo "Errore: il comando agama non e disponibile." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Errore: curl non e disponibile." >&2; exit 1; }

echo "Scarico il profilo software personale..."
curl --fail --location --silent --show-error "$PROFILE_URL" -o "$PROFILE_FILE"

echo "Carico SOLO la configurazione software nel setup Agama corrente..."
agama config load "$PROFILE_FILE"

cat <<'EOF'

Profilo software caricato.

Il file non contiene sezioni storage, bootloader, rete, lingua, utente o password:
quelle scelte restano interattive nell'interfaccia Agama.

Software richiesto dal profilo:
  - nessun pattern
  - criscore1
  - criscore2
  - sole dipendenze Required

Controlla il riepilogo Agama prima di avviare l'installazione.
EOF
