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

for cmd in grep sed tar rpmbuild mkdir rm cp ls; do
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
TMP_TAR="$BUILD_ROOT/SOURCES/.myslowroll-cc-${VERSION}.tar.gz.tmp.$$"
tar --exclude-vcs \
    --exclude='./build' \
    --exclude='./rpmbuild' \
    --exclude='./dist' \
    --exclude='./packaging' \
    --exclude='./.build-rpm.lock' \
    --exclude='./myslowroll-cc-sorgenti-unificati.txt' \
    --exclude='*.bak' \
    --transform "s,^\.,myslowroll-cc-${VERSION}," \
    -czf "$TMP_TAR" -C "$HERE" .
mv -f -- "$TMP_TAR" "$BUILD_ROOT/SOURCES/myslowroll-cc-${VERSION}.tar.gz"
TMP_TAR=""

if [[ -f "$HERE/packaging/myslowroll-cc-rpmlintrc" ]]; then
    cp -f -- "$HERE/packaging/myslowroll-cc-rpmlintrc" "$BUILD_ROOT/SOURCES/"
fi

# Assicura sincronizzazione versione tra spec e CMakeLists.txt
sed "s/^Version:.*/Version:        ${VERSION}/" "$HERE/packaging/myslowroll-cc.spec" > "$BUILD_ROOT/SPECS/myslowroll-cc.spec"

echo "=== Esecuzione rpmbuild per versione ${VERSION} ==="
rpmbuild --define "_topdir $BUILD_ROOT" -ba "$BUILD_ROOT/SPECS/myslowroll-cc.spec"

rm -f -- "$DIST_DIR"/myslowroll-cc-*.rpm
shopt -s nullglob
rpms=("$BUILD_ROOT"/RPMS/*/*.rpm "$BUILD_ROOT"/SRPMS/*.rpm)
shopt -u nullglob

if [[ ${#rpms[@]} -eq 0 ]]; then
    echo "ERRORE: Nessun pacchetto RPM generato da rpmbuild." >&2
    exit 1
fi

cp -f -- "${rpms[@]}" "$DIST_DIR/"
cp -f -- "$HERE"/packaging/myslowroll-cc.spec "$HERE"/packaging/myslowroll-cc.changes "$HERE"/packaging/myslowroll-cc-rpmlintrc "$DIST_DIR/"

echo "=== RPM creati con successo in $DIST_DIR ==="
ls -lh -- "$DIST_DIR"
