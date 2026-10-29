#!/bin/bash
# ==============================================================================
# myslowroll-golden.sh - Golden image di mySlowrollOS (snapshot -> offline image)
# ==============================================================================
# Flusso "MX Linux style" adattato a Btrfs/Snapper:
#
#   1. create  : crea uno snapshot snapper "golden-<data>" del sistema installato
#   2. send    : esporta lo snapshot in un file .btrfs (btrfs send, offline)
#   3. recover : riceve il file su un disco nuovo, sistema fstab/UUID, reinstalla
#                il bootloader con sdbootutil -> sistema identico al giorno 1
#
# Il file .btrfs e' il "disco d'oro": reinstallare = boot recovery + recover.
# Nessuna dipendenza dai repo live: tutto cio' che serve e' nello snapshot.
#
# Uso:
#   myslowroll-golden.sh create                     # sul sistema installato
#   myslowroll-golden.sh send <id> <out.btrfs> [--root <path>]
#   myslowroll-golden.sh recover <img.btrfs> <disco> [--yes]
#   myslowroll-golden.sh self-test
#
# --root <path>: oper su un root gia' montato altrove (test da host, rescue env).
# recover richiede --yes (distruttivo sul disco di destinazione).
# ==============================================================================
set -euo pipefail

SNAPPER_CFG="${SNAPPER_CFG:-root}"

log()  { echo "myslowroll-golden: $*"; }
err()  { echo "myslowroll-golden: ERRORE: $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------------------------------------------------------------- pure helpers
# Riscrive in un file fstab le vecchie UUID con le nuove (per il recover).
# Solo righe btrfs/swap/vfat: le altre restano intatte.
rewrite_fstab_uuids() {
  # $1= file fstab, $2..= coppie "vecchia:nuova"
  local file="$1" shift2 pair old new
  shift2=$2
  shift 2 || true
  cp -- "$file" "${file}.golden.bak"
  for pair in "$shift2" "$@"; do
    old="${pair%%:*}"
    new="${pair#*:}"
    [ -n "$old" ] && [ "$old" != "$new" ] || continue
    sed -i "s/UUID=${old}/UUID=${new}/g" "$file"
  done
}

# Riscrive /etc/kernel/cmdline sostituendo root=<vecchio> con root=UUID=<nuovo>
rewrite_cmdline_root() {
  local file="$1" newuuid="$2"
  cp -- "$file" "${file}.golden.bak"
  sed -i -E "s#root=[^ ]+#root=UUID=${newuuid}#" "$file"
}

# Entrate systemd-boot: rigenera "options" rimpiazzando la vecchia root=
rewrite_boot_entries() {
  # $1 = dir loader/entries, $2 = vecchia UUID, $3 = nuova UUID
  local dir="$1" old="$2" new="$3" f
  for f in "$dir"/*.conf; do
    [ -e "$f" ] || continue
    sed -i "s/root=UUID=${old}/root=UUID=${new}/g; s/root=${old}/root=UUID=${new}/g" "$f"
  done
}

# ------------------------------------------------------------------ azioni
do_create() {
  [ "$(id -u)" -eq 0 ] || die "create richiede root (sul sistema installato)"
  command -v snapper >/dev/null || die "snapper non trovato"
  local desc
desc="golden-$(date +%F-%H%M)"
  local out
  out=$(snapper -c "$SNAPPER_CFG" create --description "$desc" --print-id) \
    || die "creazione snapshot fallita"
  log "snapshot golden creato: id=${out} desc=${desc}"
  echo "$out"
}

do_send() {
  local id="$1" outfile="$2"
  local root="/" snapshots_root
  if [ "${ARG_ROOT:-/}" != "/" ]; then
    root="${ARG_ROOT}"
    snapshots_root="${root}/.snapshots/${id}/snapshot"
  else
    snapshots_root="/.snapshots/${id}/snapshot"
  fi
  [ -d "$snapshots_root" ] || die "snapshot ${id} non trovato in ${snapshots_root}"
  [ -e "$outfile" ] && die "il file di destinazione esiste gia': ${outfile}"
  command -v btrfs >/dev/null || die "btrfs non trovato"
  log "export snapshot ${id} (${snapshots_root}) -> ${outfile}"
  btrfs send -f "$outfile" "$snapshots_root"
  log "golden image creata: ${outfile} ($(du -h "$outfile" | cut -f1))"
}

do_recover() {
  local img="$1" disk="$2"
  [ "${GOLDEN_YES:-0}" = "1" ] || die "recover e' DISTRUTTIVO: rilanciare con --yes"
  [ "$(id -u)" -eq 0 ] || die "recover richiede root"
  [ -f "$img" ] || die "immagine non trovata: ${img}"
  [ -b "$disk" ] || die "disco non trovato: ${disk}"

  local mnt esp
  mnt=$(mktemp -d /tmp/golden-rec.XXXX)
  esp=$(mktemp -d /tmp/golden-esp.XXXX)

  log "partiziono ${disk}: ESP 1GiB + resto btrfs"
  wipefs -a "$disk"
  sfdisk "$disk" <<EOF
label: gpt
name=esp,  size=2097152, type=uefi
name=root,             type=linux
EOF
  partprobe "$disk" 2>/dev/null || true
  local esp_part root_part
  esp_part="${disk}1"; root_part="${disk}2"
  [ -b "$root_part" ] || root_part="${disk}p2"; [ -b "$esp_part" ] || esp_part="${disk}p1"

  log "formattazione ESP + root btrfs"
  mkfs.vfat -F32 "$esp_part"
  local newuuid
  newuuid=$(blkid -s UUID -o value "$root_part")
  # separate assign to not mask blkid failure (checked right below)
  [ -n "$newuuid" ] || die "UUID root non leggibile"
  mkfs.btrfs -f "$root_part"

  mount "$root_part" "$mnt"
  log "ricezione immagine (puo' richiedere minuti)..."
  btrfs receive "$mnt" < "$img"
  local recv_sub
  recv_sub=$(find "$mnt" -maxdepth 1 -type d ! -path "$mnt" | head -1)
  [ -n "$recv_sub" ] || die "subvolume ricevuto non trovato in ${mnt}"
  mv "$recv_sub" "$mnt/@golden"
  # default subvolume -> golden
  btrfs subvolume set-default "$mnt/@golden" 2>/dev/null || true
  rmdir "$mnt/@golden/.snapshots" 2>/dev/null || true
  btrfs subvolume create "$mnt/@golden/.snapshots" 2>/dev/null || true

  # vecchie UUID dal fstab ricevuto
  local old_root old_swap old_esp
  old_root=$(sed -n 's/.*UUID=\([0-9a-f-]*\).*\/ .*/\1/p' "$mnt/@golden/etc/fstab" | head -1)
  old_swap=$(sed -n 's/.*UUID=\([0-9a-f-]*\).*swap.*/\1/p' "$mnt/@golden/etc/fstab" | grep -v "^${old_root}$" | head -1)
  old_esp=$(sed -n 's/.*UUID=\([0-9A-Fa-f-]*\).*\/boot.*/\1/p' "$mnt/@golden/etc/fstab" | head -1)

  local new_esp
  new_esp=$(blkid -s UUID -o value "$esp_part")

  log "aggiorno UUID: root=${newuuid} esp=${new_esp}"
  # riga swap hardware rimossa: il disco di destinazione non ha swap e lo zram lo copre
  sed -i "\#^[^#]*[[:space:]]swap[[:space:]]+#d" "$mnt/@golden/etc/fstab"
  # path subvol /0/... -> /@golden/...
  sed -i 's#subvol=/0/#subvol=/@golden/#g' "$mnt/@golden/etc/fstab"
  rewrite_fstab_uuids "$mnt/@golden/etc/fstab" "${old_root}:${newuuid}" "${old_esp}:${new_esp}"
  log "fstab aggiornato: swap hardware rimosso, subvol /0/ riscritti"
  if [ -f "$mnt/@golden/etc/kernel/cmdline" ]; then
    rewrite_cmdline_root "$mnt/@golden/etc/kernel/cmdline" "$newuuid"
  fi

  mount "$esp_part" "$mnt/@golden/boot"
  log "reinstallazione bootloader (sdbootutil)"
  mount --bind "$mnt/@golden" "$mnt/@golden"
  mount --bind /dev  "$mnt/@golden/dev"  2>/dev/null || true
  mount --bind /proc "$mnt/@golden/proc" 2>/dev/null || true
  mount --bind /sys  "$mnt/@golden/sys"  2>/dev/null || true
  chroot "$mnt/@golden" /bin/bash -c "sdbootutil add-all-kernels --esp-path /boot" \
    || log "sdbootutil add-all-kernels fallito: verificare a mano dopo il reboot"
  # riscrivi le entrate gia' generate con la vecchia UUID
  rewrite_boot_entries "$mnt/@golden/boot/loader/entries" "${old_root}" "${newuuid}"
  # sdbootutil in chroot senza efivars puo' generare "root=UUID=" vuoto: lo forziamo
  for _e in "$mnt/@golden/boot/loader/entries/"*.conf; do
    [ -e "$_e" ] || continue
    sed -i "s#root=UUID=[^ ]*#root=UUID=${newuuid}#" "$_e"
  done

  umount -R "$mnt/@golden/dev" "$mnt/@golden/proc" "$mnt/@golden/sys" 2>/dev/null || true
  umount "$mnt/@golden/boot" 2>/dev/null || true
  umount "$mnt" || umount -l "$mnt"
  rmdir "$mnt" "$esp" 2>/dev/null || true

  log "RECOVER COMPLETATO su ${disk}. root UUID=${newuuid}. Reboot per avviare."
}

# ------------------------------------------------------------------ self-test
do_self_test() {
  local t
  t=$(mktemp -d) || exit 1
  SELF_TEST_DIR="$t"
  trap 'rm -rf -- "$SELF_TEST_DIR"' EXIT

  # 1. rewrite_fstab_uuids: sostituisce solo le UUID bersaglio
  cat >"$t/fstab" <<'FSTAB'
UUID=49e5f44c-aaaa-bbbb-cccc-dddddddddddd   /            btrfs  defaults,noatime             0  0
UUID=49e5f44c-aaaa-bbbb-cccc-dddddddddddd   /var         btrfs  subvol=/0/var,noatime        0  0
UUID=9af60bbd-1111-2222-3333-444444444444   swap         swap   defaults                     0  0
UUID=C2FF-33A7                              /boot        vfat   utf8,dmask=0077,umask=0077   0  0
FSTAB
  rewrite_fstab_uuids "$t/fstab" \
    "49e5f44c-aaaa-bbbb-cccc-dddddddddddd:11111111-2222-3333-4444-555555555555" \
    "C2FF-33A7:ABCD-1234"
  grep -q "UUID=11111111-2222-3333-4444-555555555555   /var" "$t/fstab" || { echo 'FAIL: fstab root non riscritta' >&2; exit 1; }
  grep -q "UUID=ABCD-1234                              /boot" "$t/fstab" || { echo 'FAIL: fstab esp non riscritta' >&2; exit 1; }
  grep -q "UUID=9af60bbd-1111-2222-3333-444444444444   swap" "$t/fstab" || { echo 'FAIL: swap modificato per errore' >&2; exit 1; }
  grep -q "subvol=/0/var,noatime" "$t/fstab" || { echo 'FAIL: opzioni fstab perse' >&2; exit 1; }
  [ -f "$t/fstab.golden.bak" ] || { echo 'FAIL: backup fstab assente' >&2; exit 1; }

  # 2. rewrite_cmdline_root
  printf 'root=/dev/vda2 rw mitigations=auto security=apparmor systemd.show_status=1 quiet\n' >"$t/cmdline"
  rewrite_cmdline_root "$t/cmdline" "99999999-8888-7777-6666-555555555555"
  grep -q "^root=UUID=99999999-8888-7777-6666-555555555555 rw mitigations=auto security=apparmor systemd.show_status=1 quiet$" "$t/cmdline" \
    || { echo 'FAIL: cmdline root non riscritta correttamente' >&2; exit 1; }
  # idempotente
  rewrite_cmdline_root "$t/cmdline" "99999999-8888-7777-6666-555555555555"
  grep -q "^root=UUID=99999999-8888-7777-6666-555555555555 rw mitigations=auto" "$t/cmdline" \
    || { echo 'FAIL: rewrite cmdline non idempotente' >&2; exit 1; }

  # 3. rewrite_boot_entries
  mkdir "$t/entries"
  cat >"$t/entries/myslowroll-7.2.11.conf" <<'ENTRY'
title mySlowrollOS
options root=UUID=49e5f44c-aaaa-bbbb-cccc-dddddddddddd rw mitigations=auto quiet rootflags=subvol=0/.snapshots/1/snapshot
ENTRY
  rewrite_boot_entries "$t/entries" "49e5f44c-aaaa-bbbb-cccc-dddddddddddd" "11111111-2222-3333-4444-555555555555"
  grep -q "options root=UUID=11111111-2222-3333-4444-555555555555 rw" "$t/entries/myslowroll-7.2.11.conf" \
    || { echo 'FAIL: boot entry non riscritta' >&2; exit 1; }
  grep -q "rootflags=subvol=0/.snapshots/1/snapshot" "$t/entries/myslowroll-7.2.11.conf" \
    || { echo 'FAIL: rootflags persa dalla boot entry' >&2; exit 1; }

  echo 'PASS: fstab/cmdline/boot-entry UUID rewrite, backup, idempotenza'
}

# ------------------------------------------------------------------- dispatch
ARG_ROOT="/"
GOLDEN_YES=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ARG_ROOT="$2"; shift 2 ;;
    --yes)  GOLDEN_YES=1; shift ;;
    *)      ARGS+=("$1"); shift ;;
  esac
done
[ ${#ARGS[@]} -ge 1 ] || usage
MODE="${ARGS[0]}"

case "$MODE" in
  create)    do_create ;;
  send)      [ ${#ARGS[@]} -ge 3 ] || die "send richiede: <id> <out.btrfs>"; do_send "${ARGS[1]}" "${ARGS[2]}" ;;
  recover)   [ ${#ARGS[@]} -ge 3 ] || die "recover richiede: <img.btrfs> <disco>"; do_recover "${ARGS[1]}" "${ARGS[2]}" ;;
  self-test) do_self_test ;;
  -h|--help|help) usage ;;
  *) die "modalita' sconosciuta: ${MODE} (vedi --help)" ;;
esac
