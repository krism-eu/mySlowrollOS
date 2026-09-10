# Protezione e aggiornamenti di mySlowrollOS

## Criscore

`criscore1` e `criscore2` sostituiscono lo “scudo” offerto dai pattern generici
openSUSE e KDE, senza importarli e senza ereditarne il contenuto sovrabbondante.
Sono due metapacchetti generati dallo stesso sorgente e dichiarano lo stesso
insieme di dipendenze forti.

In aggiunta:

- `criscore1` richiede esattamente la stessa versione-release di `criscore2`;
- `criscore2` richiede esattamente la stessa versione-release di `criscore1`;
- `experiments/rootfs/protected.seed` è l'unica fonte modificabile dei `Requires`;
- `core/generate-criscore-spec` genera materialmente entrambe le liste nello spec;
- `criscore1` installa anche `/usr/sbin/myslowroll-atomic-dup`.

Se si tenta di rimuovere un pacchetto richiesto, il solver deve quindi proporre
anche la rimozione delle due ancore. Ogni ancora ha inoltre un `%preun` che:

- consente gli aggiornamenti;
- rifiuta una vera disinstallazione;
- permette una rimozione intenzionale soltanto dopo la creazione di
  `/run/criscore.allow-removal`;
- lascia passare esclusivamente l'erase sintetico di OBS quando
  `YAST_IS_RUNNING=instsys`.

La protezione vale anche attraverso i `Requires` transitivi. Non serve elencare
ogni libreria; vanno invece dichiarati direttamente i componenti essenziali che
potrebbero arrivare solo come `Recommends`, provider sostituibili o integrazioni
runtime.

Questo protegge dalle normali operazioni RPM/Zypper/YaST. Non pretende di
fermare root che usi `--noscripts`, cancelli file a mano o modifichi il sistema
fuori dal package manager.

## Build locale e OBS

Il build locale rigenera sempre lo spec e include il tool atomico come `Source1`:

```sh
bash core/build-criscore-local
```

Per preparare le sorgenti OBS:

```sh
bash core/prepare-criscore-obs
```

La directory di staging contiene entrambi i file richiesti da OBS:

```text
criscore1.spec
myslowroll-atomic-dup
```

Un solo package sorgente OBS, `criscore1`, continua a produrre i due RPM binari
`criscore1` e `criscore2`.

## Pulizia protetta dei pacchetti non necessari

`core/criscore-clean-orphans` applica controlli fail-closed prima di rimuovere
pacchetti che Zypper considera non necessari:

1. richiede entrambe le ancore;
2. le esclude dall'elenco iniziale;
3. esegue un `remove --dry-run --clean-deps` in XML;
4. annulla se il piano coinvolge una delle ancore.

Il `%preun` rimane comunque l'ultima barriera.

## Aggiornamento atomico della workstation RW

La workstation resta **openSUSE Slowroll tradizionale con root Btrfs
read-write**. Non viene trasformata in MicroOS e non viene adottato il ruolo
Transactional Server.

Per i soli distribution upgrade completi usiamo però il motore ufficiale
`transactional-update`: il `zypper dup` viene eseguito dentro una nuova snapshot
Btrfs e la root corrente non viene modificata. Il nuovo stato diventa la root di
default soltanto per il reboot successivo.

Questo modello è compatibile con una root read-write, ma ha una conseguenza
importante: dopo la creazione della nuova snapshot, ulteriori modifiche alla
root attualmente in esecuzione non fanno parte della snapshot preparata e
andrebbero perse al cambio di root. Per questo il wrapper del progetto non
restituisce una shell dopo un upgrade riuscito: verifica il target e ordina
subito il reboot.

### Guardrail del wrapper

`core/myslowroll-atomic-dup` lavora in modalità fail-closed. Prima di creare una
transazione richiede:

- openSUSE Slowroll;
- root Btrfs montata read-write e subvolume con proprietà `ro=false`;
- Snapper configurato per `/` e `/.snapshots` disponibile;
- `/var` montata separatamente dalla root snapshot;
- systemd-boot gestito da `sdbootutil`;
- snapshot attiva uguale alla snapshot di default;
- `criscore1` e `criscore2` entrambi installati;
- assenza di `/run/criscore.allow-removal`;
- `solver.onlyRequires = true`;
- `solver.dupAllowVendorChange = false`;
- `transactional-update.timer` disabilitato;
- nessuna transazione precedente ancora da confermare;
- nessun altro processo ZYpp attivo.

La policy Agama imposta i due valori ZYpp e disabilita/maska il timer automatico.
Gli upgrade completi restano quindi intenzionalmente manuali.

### Comandi

```sh
sudo myslowroll-atomic-dup status
sudo myslowroll-atomic-dup check
sudo myslowroll-atomic-dup plan
sudo myslowroll-atomic-dup upgrade
sudo myslowroll-atomic-dup confirm
sudo myslowroll-atomic-dup rollback [SNAPSHOT]
```

`plan` aggiorna i metadati, esegue un dry-run leggibile e poi un dry-run XML con
`--download-only`, `--no-recommends` e `--no-allow-vendor-change`. In questo modo
gli RPM vengono pre-scaricati e Zypper può anche eseguire il controllo dei
conflitti di file senza modificare il sistema. Il piano viene rifiutato se
prevede la rimozione di componenti critici.

`upgrade` ripete sempre il piano, richiede una conferma esplicita, crea prima una
snapshot di recupero read-only e ne verifica la presenza nel bootloader. Solo a
quel punto esegue:

```text
transactional-update --no-selfupdate --non-interactive --drop-if-no-change dup
```

Dopo il completamento verifica che la nuova snapshot:

- sia ancora Slowroll;
- contenga criscore, kernel, RPM/Zypper, Snapper, transactional-update e
  systemd-boot;
- sia considerata bootable da `sdbootutil`;
- sia ancora read-write (`ro=false`).

Se tutto è coerente, registra il target sotto `/var/lib/myslowroll/atomic-dup` e
riavvia immediatamente. Dopo un boot riuscito `confirm` controlla che snapshot
attiva e default coincidano con il target e marca la transazione come confermata.
La snapshot di recupero viene conservata.

`rollback` usa, per default, proprio il punto di recupero registrato. È
intenzionalmente meno dipendente dallo stato software della nuova root: deve
restare utilizzabile anche se il target appena avviato ha un package set
incompleto. Il rollback prepara una nuova snapshot RW tramite il meccanismo
ufficiale e riavvia immediatamente.

## Stato di validazione

Sono già validati sul percorso reale Agama/Slowroll in VM:

- installazione del profilo senza pattern distro/desktop;
- avvio e SDDM;
- installazione di `criscore1` e `criscore2` dal repository OBS;
- blocco reale della rimozione di un pacchetto protetto (`dolphin`).

Per il wrapper atomico sono stati eseguiti controlli statici e test del parser
fail-closed del piano. La VM corrente usa ext4: lì `check` deve e può soltanto
rifiutare l'operazione senza modificare nulla. La validazione dell'upgrade e del
rollback atomico richiede una VM dedicata con root Btrfs, Snapper e systemd-boot.
La procedura precisa è in `core/atomic-upgrade-test.md`.
