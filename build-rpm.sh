#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUILD_ROOT="$HERE/rpmbuild"
DIST_DIR="$HERE/dist"
LOCK_DIR="$HERE/.build-rpm.lock"
TMP_TAR=""

cleanup() {
    if [[ -n "${TMP_TAR:-}" && -f "$TMP_TAR" ]]; then
        rm -f -- "$TMP_TAR"
    fi
    rmdir -- "$LOCK_DIR" 2>/dev/null || true
}

for cmd in grep sed tar rpmbuild mkdir rm cp ls python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERRORE: Comando richiesto non trovato: $cmd" >&2
        exit 1
    fi
done

if [[ "$HERE" == *[[:space:]%]* ]]; then
    echo "ERRORE: Il percorso del progetto non può contenere spazi o il carattere '%': $HERE" >&2
    exit 1
fi

if ! mkdir -- "$LOCK_DIR" 2>/dev/null; then
    echo "ERRORE: Un'altra istanza di build-rpm.sh è già in esecuzione ($LOCK_DIR)." >&2
    exit 1
fi
trap cleanup EXIT INT TERM

if [[ ! -r "$HERE/CMakeLists.txt" ]]; then
    echo "ERRORE: File CMakeLists.txt mancante o non leggibile in $HERE" >&2
    exit 1
fi

if [[ ! -r "$HERE/packaging/myslowroll-cc.spec" ]]; then
    echo "ERRORE: Specfile packaging/myslowroll-cc.spec mancante o non leggibile" >&2
    exit 1
fi

# Single Source of Truth: estrai e valida versione da CMakeLists.txt
VERSION=$(grep -oP 'project\(myslowroll-cc\s+VERSION\s+\K[0-9]+\.[0-9]+\.[0-9]+' "$HERE/CMakeLists.txt" | head -n 1 || true)
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERRORE: Impossibile estrarre una versione valida (X.Y.Z) da CMakeLists.txt" >&2
    exit 1
fi

rm -rf -- "$BUILD_ROOT"
mkdir -p -- "$BUILD_ROOT"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} "$DIST_DIR"

echo "=== Creazione tarball sorgente myslowroll-cc-${VERSION}.tar.gz ==="
python3 -c "
import tarfile, os, sys

here = sys.argv[1]
version = sys.argv[2]
out_tar = sys.argv[3]

excludes = {'build', 'rpmbuild', 'dist', 'packaging', '.build-rpm.lock', 'myslowroll-cc-sorgenti-unificati.txt', '.git'}

def filter_func(tarinfo):
    parts = tarinfo.name.split('/')
    if len(parts) > 1 and parts[1] in excludes:
        return None
    if tarinfo.name.endswith('.bak'):
        return None
    return tarinfo

with tarfile.open(out_tar, 'w:gz') as tar:
    tar.add(here, arcname=f'myslowroll-cc-{version}', filter=filter_func)
" "$HERE" "$VERSION" "$BUILD_ROOT/SOURCES/myslowroll-cc-${VERSION}.tar.gz"

if [[ -f "$HERE/packaging/myslowroll-cc-rpmlintrc" ]]; then
    cp -f -- "$HERE/packaging/myslowroll-cc-rpmlintrc" "$BUILD_ROOT/SOURCES/"
fi

# Assicura sincronizzazione versione tra spec e CMakeLists.txt
sed "s/^Version:.*/Version:        ${VERSION}/" "$HERE/packaging/myslowroll-cc.spec" > "$BUILD_ROOT/SPECS/myslowroll-cc.spec"

echo "=== Esecuzione rpmbuild per versione ${VERSION} ==="
rpmbuild --define "_topdir $BUILD_ROOT" --define "_tmppath /tmp" -ba "$BUILD_ROOT/SPECS/myslowroll-cc.spec"

rm -f -- "$DIST_DIR"/myslowroll-cc-*.rpm
shopt -s nullglob
rpms=("$BUILD_ROOT"/RPMS/*/*.rpm "$BUILD_ROOT"/SRPMS/*.rpm)
shopt -u nullglob

if [[ ${#rpms[@]} -eq 0 ]]; then
    echo "ERRORE: Nessun pacchetto RPM generato da rpmbuild." >&2
    exit 1
fi

cp -f -- "${rpms[@]}" "$DIST_DIR/"
cp -f -- "$BUILD_ROOT/SOURCES/myslowroll-cc-${VERSION}.tar.gz" "$DIST_DIR/"
for pkg_file in myslowroll-cc.spec myslowroll-cc.changes myslowroll-cc-rpmlintrc; do
    if [[ -f "$HERE/packaging/$pkg_file" ]]; then
        cp -f -- "$HERE/packaging/$pkg_file" "$DIST_DIR/"
    fi
done

echo "=== RPM creati con successo in $DIST_DIR ==="
ls -lh -- "$DIST_DIR"
