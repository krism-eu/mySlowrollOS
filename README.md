# mySlowrollOS

Workstation personale, minimale e riproducibile basata su **openSUSE Slowroll**, Plasma Wayland, Btrfs e Snapper.

L'obiettivo non e creare un fork di Slowroll e non e duplicare la distribuzione.
Slowroll resta la base; il progetto definisce soltanto il contratto software personale
e le integrazioni necessarie.

## Decisioni fissate

- base: openSUSE Slowroll classico RW;
- desktop: Plasma su Wayland;
- nessuna sessione Plasma X11 e nessun server Xorg completo;
- /home su partizione separata;
- root Btrfs con Snapper e integrazione ZYpp native;
- AppArmor; nessuna policy SELinux attiva;
- YaST grafico mantenuto finche disponibile;
- niente installazione automatica delle dipendenze raccomandate;
- nessun pattern desktop usato per definire il sistema personale;
- i pacchetti necessari all'uso normale sono dichiarati dai due RPM personali OBS;
- applicazioni e accessori non essenziali restano rimovibili.

XWayland puo essere mantenuto come strato di compatibilita senza installare una
sessione Plasma X11 completa.

## Contratto software

I due RPM personali pubblicati su OBS sono:

- `criscore1`
- `criscore2`

Il repository e:

`https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/`

Le dipendenze dei due RPM costituiscono la fonte autorevole del software richiesto.
L'installer non deve duplicare la stessa lista in un secondo manifest.

## Installazione con Agama

La directory `agama/` contiene un **profilo parziale**, non un profilo unattended
completo.

`agama/personal-software.json` modifica esclusivamente la sezione software:

- `patterns: []`
- `packages: [criscore1, criscore2]`
- repository OBS personale
- `onlyRequired: true`

Non contiene storage, utente, password, rete o localizzazione.

Questo e intenzionale: il profilo viene caricato dentro una installazione Agama
interattiva con `agama config load`, cosi disco, partizioni, filesystem, mount,
bootloader, lingua, fuso orario e account restano scelte dell'utente.

Vedi `agama/README.md` per il flusso operativo.

## Recovery e aggiornamenti

Il recovery di base e quello nativo openSUSE: Btrfs + Snapper.

L'updater atomico sperimentale presente nel repository e materiale separato e non
fa parte del contratto dell'installer. Una eventuale versione semplificata verra
mantenuta solo se aggiunge un vantaggio concreto rispetto al normale
`zypper dup` protetto da Snapper.

## Principio di manutenzione

Una sola fonte autorevole per ogni responsabilita:

- software base personale: RPM OBS;
- installazione: Agama interattivo + overlay software parziale;
- recovery root: Snapper;
- amministrazione grafica: strumenti openSUSE esistenti (YaST / successori);
- codice custom: solo dove manca davvero una funzione.
