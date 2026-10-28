# mySlowrollOS — Procedura di Costruzione ISO con KIWI su OBS

Guida completa per creare l'immagine ISO Live Installer di **mySlowrollOS** utilizzando **KIWI NG** e **Agama** su Open Build Service (OBS).

---

## Architettura della ISO Installer

La ISO di installazione combina l'ambiente live ufficiale **Agama** con la personalizzazione completa **mySlowrollOS**:
1. **100% Autonoma (Zero dipendenze esterne durante l'installazione)**:
   - Il profilo di installazione [`profile-final.jsonnet`](root/usr/share/myslowroll/profile-final.jsonnet) è incorporato nel filesystem live in `/usr/share/myslowroll/profile-final.jsonnet`.
   - Tutti i 21 file di configurazione (`myslowroll-policy/`), gli script (`post-chroot-boot-policy.sh`, `init-firstboot.sh`) e le chiavi GPG sono inclusi nella directory overlay `root/usr/share/myslowroll/` e referenziati con URI `file:///usr/share/myslowroll/...`.
2. **Kiosk Grafico Locale (Wayland Cage + Firefox)**:
   - Include il server Wayland `cage` e `MozillaFirefox` per visualizzare direttamente sullo schermo locale l'interfaccia web di Agama, oltre a consentire l'accesso remoto via browser su `https://agama.local`.
3. **Setup semi-interattivo**:
   - Il kernel cmdline del bootloader avvia Agama con:
     ```text
     inst.auto=file:///usr/share/myslowroll/profile-final.jsonnet inst.install=0
     ```
   - `inst.auto=file:///...`: pre-carica automaticamente la lista pacchetti (`criscore1/2`, `myslowroll-cc`, `atomic-update`), kernel, preset, zram e policy di sistema.
   - `inst.install=0`: impedisce l'installazione automatica non presidiata; la configurazione dischi/partizioni e le credenziali utente rimangono **completamente interattive**.
4. **Repository mySlowrollOS integrato**:
   - I pacchetti protetti e il Control Center sono risolti dal repository `home:krism` (priorità 90).

---

## Struttura della Recipe

```text
obs/agama-installer/
├── README.md                     # Questa guida
├── agama-installer.kiwi           # Ricetta KIWI NG completa (schemaversion 8.5 per Kiwi 10.3+)
├── config.sh                     # Script di configurazione chroot KIWI
├── sync-installer-assets.py      # Sincronizzazione automatica e verifica (--check)
└── root/                         # Overlay del filesystem incorporato nella Live ISO
    └── usr/share/myslowroll/
        ├── profile-final.jsonnet # Profilo Agama offline (file://)
        ├── myslowroll-policy/    # I 19 file di policy e configurazione di sistema
        └── agama/                # Script post/init e chiavi GPG
```

### Verifica e Sincronizzazione degli Asset

- **Verifica integrità (CI / Pre-commit)**:
  ```bash
  python3 obs/agama-installer/sync-installer-assets.py --check
  ```
- **Rigenerazione overlay (se cambiano file sorgente nel repo)**:
  ```bash
  python3 obs/agama-installer/sync-installer-assets.py
  ```

---

## Procedura Operativa in 5 Fasi

### Fase 1: Creazione del Pacchetto su OBS

Nel tuo progetto OBS (`home:krism`), crea o apri il pacchetto `agama-installer`:
```bash
osc mkpac home:krism agama-installer
cd home:krism/agama-installer
cp -a /percorso/a/mySlowrollOS/obs/agama-installer/* .
```

---

### Fase 2: Configurazione del Repository OBS (`prjconf`)

Affinché OBS tratti il pacchetto come immagine ISO (e non come un normale RPM), il repository deve avere il tipo configurato su `kiwi`:

1. Nel tuo progetto `home:krism`, modifica la configurazione:
   ```bash
   osc meta prjconf home:krism -e
   ```
2. Aggiungi la direttiva:
   ```text
   Type: kiwi
   ```
3. L'immagine finale generata verrà pubblicata nella sezione **`home:krism/images/`** di download.opensuse.org.

---

### Fase 3: Prerequisiti Pacchetti su OBS

Prima di compilare la ISO, assicurati che i pacchetti `home:krism` siano stati caricati e compilati con successo (`succeeded`):
1. **`myslowroll-cc`**: Sorgenti e spec da `KSCC/dist/`.
2. **`criscore1`**: Spec e sorgenti da `OS/mySlowrollOS/obs/criscore1/`.
3. **`atomic-update`**: Spec e script da `OS/mySlowrollOS/atomic-update/`.

---

### Fase 4: Commit su OBS e Monitoraggio Build

Invia i file al Build Service:
```bash
cd home:krism/agama-installer
osc status
osc addremove
osc commit -m "build(iso): mySlowrollOS Agama Live Installer with offline profile, cage kiosk and branding"
```

Monitora l'avanzamento della build ISO:
```bash
osc results home:krism agama-installer
osc buildlog home:krism agama-installer images x86_64
```

Una volta terminata la compilazione, scarica la ISO generata:
`https://download.opensuse.org/repositories/home:/krism/images/`

---

### Fase 5: Validazione in Macchina Virtuale (Pre-Hardware)

Prima di effettuare la reinstallazione sul disco fisico, esegui il test end-to-end su una VM QEMU/KVM:

```bash
qemu-system-x86_64 \
    -enable-kvm \
    -m 4096 \
    -smp 4 \
    -bios /usr/share/qemu/ovmf-x86_64.bin \
    -drive file=test-vm-disk.qcow2,if=virtio,format=qcow2 \
    -cdrom mySlowrollOS-Agama-installer.x86_64.iso \
    -boot d \
    -vga virtio \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0
```

#### Checklist di verifica in VM:
- [ ] Il bootloader UEFI avvia Agama con `inst.auto=file:///...` pre-caricato.
- [ ] Cage avvia Firefox in modalità kiosk visualizzando localmente la schermata di Agama.
- [ ] Agama mostra la selezione semi-interattiva: dischi e credenziali configurabili manualmente.
- [ ] Nessun errore di download (tutti i file di policy e script sono letti localmente).
- [ ] Installazione completata con successo.
- [ ] Al primo boot da disco: `systemd-boot` avvia la snapshot RW Btrfs `@/.snapshots/1/snapshot`.
- [ ] `myslowroll-cc` si avvia correttamente e visualizza lo stato del sistema e di `atomic-update`.
