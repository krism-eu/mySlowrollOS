# mySlowrollOS — Procedura di Costruzione ISO con KIWI su OBS

Guida completa per creare l'immagine ISO Live Installer di **mySlowrollOS** utilizzando **KIWI NG** e **Agama** su Open Build Service (OBS).

---

## Architettura della ISO Installer

La ISO di installazione combina l'ambiente live ufficiale **Agama** con la personalizzazione completa **mySlowrollOS**:
1. **100% Autonoma (Zero dipendenze esterne durante l'installazione)**:
   - Il profilo di installazione [`profile-final.jsonnet`](root/usr/share/myslowroll/profile-final.jsonnet) è incorporato nel filesystem live in `/usr/share/myslowroll/profile-final.jsonnet`.
   - Tutti i file di configurazione (`myslowroll-policy/`), gli script (`post-chroot-boot-policy.sh`, `init-firstboot.sh`) e le chiavi GPG sono inclusi nella directory `root/usr/share/myslowroll/` e referenziati con URI `file:///usr/share/myslowroll/...`.
2. **Setup semi-interattivo**:
   - La riga di comando del kernel nel bootloader della ISO avvia Agama con:
     ```text
     inst.auto=file:///usr/share/myslowroll/profile-final.jsonnet inst.install=0
     ```
   - `inst.auto=file:///...`: pre-carica automaticamente la lista pacchetti (`criscore1/2`, `myslowroll-cc`, `atomic-update`), kernel, preset, zram e policy di sistema.
   - `inst.install=0`: impedisce l'installazione automatica non presidiata; il partizionamento del disco e la creazione delle credenziali utente rimangono **completamente interattive**.
3. **Repository mySlowrollOS integrato**:
   - I pacchetti protetti e il Control Center sono risolti dal repository `home:krism`.

---

## Struttura della Recipe

```text
obs/agama-installer/
├── README.md                     # Questa guida
├── agama-installer.kiwi           # Ricetta KIWI NG completa per OBS
├── config.sh                     # Script di configurazione chroot KIWI
├── config.sh.delta               # Delta da aggiungere se si usa un branch upstream
├── iso-delta.kiwi.xml            # Delta XML da applicare a una ricetta upstream
├── sync-installer-assets.py      # Script di sincronizzazione automatica degli asset
└── root/                         # Overlay del filesystem incorporato nella Live ISO
    └── usr/share/myslowroll/
        ├── profile-final.jsonnet # Profilo Agama offline (file://)
        ├── myslowroll-policy/    # I 19 file di policy e configurazione di sistema
        └── agama/                # Script post/init e chiavi GPG
```

Per aggiornare o rigenerare la directory `root/` e il profilo offline ogni volta che cambiano file o script:
```bash
python3 obs/agama-installer/sync-installer-assets.py
```

---

## Procedura Operativa in 6 Fasi

### Fase 1: Creazione del Pacchetto su OBS

Puoi procedere in due modalità:

#### Modalità A: Pacchetto Diretto (Consigliata)
1. Nel tuo progetto OBS (`home:krism`), crea un nuovo pacchetto chiamato `agama-installer`:
   ```bash
   osc mkpac home:krism agama-installer
   ```
2. Copia i file di questa directory (`agama-installer.kiwi`, `config.sh`, e la cartella `root/`) nella cartella del pacchetto locale:
   ```bash
   cd home:krism/agama-installer
   cp -a /percorso/a/mySlowrollOS/obs/agama-installer/* .
   ```

#### Modalità B: Branch da openSUSE Slowroll
1. Esegui il branch dell'installer Agama ufficiale:
   ```bash
   osc branch openSUSE:Slowroll/agama-installer home:krism/agama-installer
   cd home:krism/agama-installer
   ```
2. Applica le modifiche:
   - Modifica `agama-installer.kiwi` inserendo i nodi di [`iso-delta.kiwi.xml`](iso-delta.kiwi.xml).
   - Accoda [`config.sh.delta`](config.sh.delta) al file `config.sh`.
   - Copia la cartella `root/`:
     ```bash
     cp -a /percorso/a/mySlowrollOS/obs/agama-installer/root .
     ```

---

### Fase 2: Configurazione del Repository OBS (`prjconf`)

Affinché OBS tratti il pacchetto come immagine ISO (e non come un normale RPM), il repository deve avere il tipo configurato su `kiwi`:

1. Nel tuo progetto `home:krism`, apri la configurazione del progetto:
   ```bash
   osc meta prjconf home:krism -e
   ```
2. Aggiungi la riga:
   ```text
   Type: kiwi
   ```
3. L'immagine finale generata verrà pubblicata nella sezione **`home:krism/images/`** di download.opensuse.org.

---

### Fase 3: Verifica dei Pacchetti Prerequisito su OBS

Prima di compilare la ISO, assicurati che i pacchetti `home:krism` siano stati caricati e compilati con successo con stato `succeeded`:
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
osc commit -m "build(iso): mySlowrollOS Agama Live Installer with offline profile and branding"
```

Monitora l'avanzamento della build ISO:
```bash
osc results home:krism agama-installer
osc buildlog home:krism agama-installer images x86_64
```

Una volta terminata la compilazione, scarica la ISO generata:
`https://download.opensuse.org/repositories/home:/krism/images/`

---

### Fase 5: Validazione Obbligatoria in Macchina Virtuale (Pre-Hardware)

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
- [ ] Agama mostra la schermata semi-interattiva: dischi e utente configurabili manualmente.
- [ ] Nessun errore di download (tutti i file di policy e script sono letti dal filesystem locale).
- [ ] Installazione completata con successo.
- [ ] Al primo boot da disco: `systemd-boot` avvia la snapshot RW Btrfs `@/.snapshots/1/snapshot`.
- [ ] `myslowroll-cc` si avvia correttamente e visualizza lo stato del sistema e di `atomic-update`.
