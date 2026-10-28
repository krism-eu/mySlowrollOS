# MSCC · mySlowrollOS Control Center (`myslowroll-cc`)

Centro di Controllo Operativo desktop in **C++20 / Qt 6 / KDE Kirigami 6** per **mySlowrollOS / openSUSE Slowroll**.

---

## Panoramica dei Moduli & Funzionalità

1. **Dashboard**:
   - Monitoraggio real-time di CPU (%), RAM reale in uso (esclusi cache/buffer), temperatura CPU e spazio disco per `/` e `/home`.
   - Stato sintetico del motore `atomic-update` e dello snapshot Btrfs attivo/predefinito.
   - Stato firmware UEFI (`BootCurrent` e `BootNext` tramite `efibootmgr`).
   - Stato connettività di rete e controllo rapido Wi-Fi (con rilevamento blocco hardware `rfkill`).
   - Segnalazione immediata di aggiornamenti pronti per il riavvio o unità systemd fallite.

2. **Software RPM**:
   - Lanciatori rapidi per **YaST Gestione Software**, **KDE Discover** e pulizia cache `zypper` con conferma.
   - Integrazione con **Kontainer** per la gestione di container Podman/Distrobox (nativo, Flatpak o ricerca in Discover).
   - Consultazione su richiesta dei repository configurati in `/etc/zypp/repos.d` e collegamento a **YaST Repository**.

3. **Servizi & Rete**:
   - Monitoraggio e riavvio con conferma dei servizi chiave (`firewalld`, `NetworkManager`, `bluetooth`, `cups`).
   - Ispezione delle unità systemd fallite con visualizzatore log `journalctl`.
   - Commutazione rapida tra 4 profili di rete IPv4 (DHCP o IP statico/CIDR/Gateway) e 4 profili DNS con campo annotazione URL DoH.
   - Scorciatoie per **Firewall di Plasma** e **YaST Rete (LAN)**.

4. **Sistema & Boot**:
   - Selezione rapida del prossimo avvio UEFI (`BootNext` via `efibootmgr`).
   - Classifica real-time dei 6 processi a maggior consumo di memoria fisica (RSS).
   - Riavvio controllato del sistema e riavvio diretto nel setup del firmware UEFI (su sistemi `/sys/firmware/efi`).
   - Profili energetici e sospensione per KDE PowerDevil su alimentazione AC (`Standard`, `60 min`, `180 min`).
   - Scorciatoie per **KDE Partition Manager**, **YaST Sysconfig** e **YaST Utenti**.

5. **Backup & Recovery**:
   - Avvio rapido di **Back In Time** per il backup dei dati personali.
   - Rilevamento dello snapshot Btrfs attivo da `/proc/self/mountinfo` e monitoraggio stato `atomic-update`.
   - Collegamento diretto a **YaST Snapper**.

6. **Comandi**:
   - **Predefiniti (Diagnostica)**: catalogo ricercabile di comandi diagnostici di sola lettura con copia ed esecuzione integrata.
   - **Miei Comandi**: fino a 12 azioni Bash personali salvate in `~/.config/myslowroll-cc/custom-actions.json` con azzeramento e archiviazione automatica in caso di file corrotto (`.corrupt-<timestamp>`).
   - **Utility Shell**: applicazione e ripristino di preset per il prompt Bash in `~/.bashrc` (con backup `~/.bashrc.bak`).

7. **Strumenti & Fix**:
   - **Manutenzione e recupero spazio**: svuotamento cestino utente, pulizia journal di sistema (`16M` via PolKit), rimozione runtime Flatpak inutilizzati, pulizia miniature (con conferma), pulizia cache Zypper e lancio di **QDirStat**.
   - **Riparazioni e Fix Desktop**: riavvio dello stack utente PipeWire/WirePlumber e ricostruzione cache `kbuildsycoca6` / `fc-cache`.
   - **Sviluppo & Dispositivi**: avvio interfaccia di configurazione **Git** e gestione dispositivi **Android (ADB)** tramite `python3-mast`.

---

## Compilazione, Test e Packaging RPM

### Compilazione e test unitari CTest:
```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
cmake --build build -j$(nproc)
ctest --test-dir build --output-on-failure
```

### Creazione del pacchetto RPM:
```bash
./build-rpm.sh
```
I pacchetti `.rpm` e `.src.rpm` vengono generati nella cartella `dist/`.

### Generazione file unificato dei sorgenti:
```bash
python3 generate-unified-sources.py
```
