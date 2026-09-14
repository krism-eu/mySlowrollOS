# Atomic Dup v4 — matrice RC1 in VM

Questa matrice valida il prototipo `myslowroll-atomic-dup-v4-tukit-preview.sh`.
Non promuove v4 a sostituto della v3.4.9: fino al completamento di tutte le
prove, la baseline operativa resta `myslowroll-atomic-dup-v3.4.9-tested.sh`.

## Invarianti

- `SOURCE` non viene mai modificata da Zypper.
- `TARGET` nasce da `tukit open`, resta RW e riceve l'intero `zypper dup`.
- RPMDB, manifest e controlli post-dup sono eseguiti nel `TARGET`.
- `/var/cache`, state e log v4 usano namespace separati e persistenti.
- La ESP è esterna alla snapshot: `SOURCE` e `TARGET` restano entrambi bootable.
- `recover` non abortisce né elimina mai una `TARGET` attiva o default.
- Tra apertura del `TARGET` e reboot non si esegue amministrazione di pacchetti
  o sistema sulla `SOURCE`.
- La root attiva è una snapshot-root RW numerata `/.snapshots/N/snapshot`, non
  la root classica `subvol=/@`, ed è uguale alla snapshot default.
- Un marker durevole creato subito prima di `tukit open` rende verificabile il drift
  dei file regolari della `SOURCE` in `/etc`; sono esclusi soltanto
  `/etc/resolv.conf`, `/etc/mtab` e `/etc/adjtime`.

Prima delle prove distruttive riservare 5–8 GiB liberi. È una precondizione di
collaudo, non un controllo hard-coded nello script.

## Inventario obbligatorio

Registrare nel report:

```sh
tukit --version
tukit --help
cat /etc/tukit.conf
snapper -c root get-config
findmnt -R /
findmnt -R /var
findmnt -R /run
bootctl status
sdbootutil --help
transactional-update --version
systemctl status transactional-update.timer transactional-update.service
```

Verificare empiricamente la sintassi numerica installata di
`sdbootutil is-bootable SNAPSHOT` e `sdbootutil add-all-kernels SNAPSHOT`, oltre
alla disponibilità reale del rollback Snapper. Conservare output completo,
versione pacchetto e codice di ritorno.

## Sequenza RC1

1. Catturare inventario, snapshot attiva/default, hash RPM della `SOURCE` e
   contenuto ESP iniziale.
2. Eseguire soltanto `check`, `plan` e `status`; lo stato atteso è `planned`.
3. Verificare hash durevoli di piano, cache e manifest RPM pre.
   Se il piano è vuoto, terminare `confirmed` qui: non aprire una `TARGET` e non
   eseguire `tukit close`.
4. Abilitare il futuro `probe-target` soltanto nella VM usa-e-getta.
5. Il probe deve dimostrare, nell'ordine:
   - parsing non ambiguo dell'output effettivo di `tukit open`;
   - `TARGET` RW;
   - marker scritto nella cache host visibile con lo stesso contenuto nel
     `TARGET`;
   - manifest RPM pre identici tra `SOURCE` e `TARGET`;
   - dry-run Zypper nel `TARGET` semanticamente uguale al piano della `SOURCE`;
   - `tukit call TARGET true` funzionante;
   - `ID=opensuse-slowroll` nel `TARGET`;
   - comportamento di `/run` esplicitamente registrato, inclusa visibilità dei
     lock reali `/run/zypp.pid` e `/run/zypp-rpm.pid`;
   - fingerprint RPM della `SOURCE` invariato;
   - abort/eliminazione del solo `TARGET`, entry BLS comprese;
   - ritorno allo stato `planned` con `SOURCE` attiva/default e bootable.

Il probe deve fallire chiuso e lasciare uno stato recuperabile se l'output di
`tukit open` non è riconosciuto. Non deve ripetere automaticamente `open`.

## Matrice crash e lock

| Punto di interruzione | Iniezione | Stato durevole atteso | Recovery attesa |
|---|---|---|---|
| prima di `tukit open` | `kill -9` / poweroff VM | `planned` o `target-opening` | nessuna modifica RPM; individuazione per txid se open ambiguo |
| subito dopo `open` | `kill -9` / poweroff VM | `target-prepared` | abort del solo TARGET se non attivo/default |
| prima di Zypper | lock ZYpp vivo | `target-prepared` | blocco azionabile; nessun dup |
| lock PID stale | file con PID inesistente | `target-prepared` | non bloccare genericamente; proseguire solo se ZYpp è realmente idle |
| `transactional-update.service` attivo | avvio concorrente | `target-prepared` | blocco fino a termine servizio |
| `transactional-update.service` failed | servizio failed | `target-prepared` | messaggio con `systemctl status` e `journalctl` |
| metà `zypper dup` | `kill -9` / poweroff VM | `target-updating` | abort TARGET; SOURCE invariata |
| `%posttrans` kernel | `kill -9` / poweroff VM | `target-updating` | inventario delta ESP; SOURCE ancora bootable; rimozione sicura degli artefatti TARGET |
| metà verifica | `kill -9` / poweroff VM | `target-verifying` | abort TARGET; SOURCE invariata |
| prima di `close` | `kill -9` | `committing` | decisione da active/default, mai retry cieco |
| durante `close` | poweroff VM | `committing` | `default=SOURCE`: abort; `default=TARGET`: verifica e pending-reboot |
| dopo `close` | `kill -9` / poweroff VM | `committing` o `pending-reboot` | entrambe le entry bootable; reboot TARGET |
| dopo reboot TARGET | `kill -9` | `pending-reboot` | non abortire TARGET attiva; riprendere conferma |

Ripetere la matrice con aggiornamento kernel e senza aggiornamento kernel. Nel
secondo caso `sdbootutil add-all-kernels TARGET` deve comunque produrre una
entry valida quando `is-bootable TARGET` fallisce.

Durante il caso kernel registrare la ESP prima del dup, durante/interrompendo il
`%posttrans` e dopo recovery. Il report deve identificare esattamente quali BLS,
kernel e initrd sono stati scritti dagli scriptlet eseguiti dentro `tukit call`,
se sono associati a SOURCE o TARGET, e se la pulizia del TARGET lascia intatta
l'entry della SOURCE. Questa prova è bloccante anche quando
`sdbootutil-snapper` è installato: il comportamento del build effettivo va
osservato, non assunto.

Eseguire inoltre un caso no-op completo. Il piano vuoto deve essere rilevato
prima di `tukit open`; stato finale `confirmed`, nessuna nuova snapshot, nessuna
scrittura ESP e fingerprint SOURCE invariato.

## Criteri PASS

- Nessun test modifica l'RPMDB della `SOURCE` dopo `tukit open`.
- Ogni transizione critica è persistita e sincronizzata prima dell'azione.
- `tukit close` conserva `TARGET` RW senza forzare proprietà Btrfs.
- State, cache, log e manifest sopravvivono a crash e reboot.
- Prune/rotazione rimuovono solo artefatti v4 scaduti e mai la transazione
  corrente.
- I messaggi di errore indicano stato, rischio e azione successiva.
- `confirm` da `TARGET` verifica persistenza, manifest RPM e unità systemd.
- Tutti i casi ambigui restano fail-closed.

Solo dopo PASS completo si può integrare il sorgente v3.4.9, sbloccare i comandi
mutanti e iniziare un collaudo reale separato.
