# mySlowrollOS

Workstation personale, minimale e riproducibile basata su **openSUSE Slowroll**, Plasma Wayland, Btrfs e Snapper.

L'obiettivo non è creare un fork di Slowroll, ma descrivere e costruire tramite Open Build Service un sistema resistente alle modifiche accidentali.

## Decisioni fissate

- base: openSUSE Slowroll;
- desktop: Plasma su Wayland;
- nessuna sessione Plasma X11 e nessun server Xorg completo;
- `/home` su partizione separata;
- root Btrfs con Snapper e integrazione ZYpp;
- AppArmor; nessuna policy SELinux attiva;
- YaST grafico mantenuto finché disponibile;
- niente installazione automatica delle dipendenze raccomandate;
- pacchetti necessari all'uso normale dichiarati esplicitamente;
- un RPM `myslowroll-core` proteggerà il nucleo dalla rimozione accidentale;
- applicazioni e accessori non essenziali resteranno rimovibili.

Xwayland sarà valutato separatamente: offre compatibilità alle applicazioni legacy senza installare una sessione X11 completa.

## Build

OBS userà direttamente i repository di `openSUSE:Slowroll`.

Il progetto avrà inizialmente due soli componenti:

1. `myslowroll-core`: metapacchetto RPM con le dipendenze indispensabili e una protezione esplicita dalla disinstallazione accidentale;
2. `myslowroll-image`: descrizione KIWI della workstation e immagine di verifica.

La pipeline ufficiale del DVD Slowroll basata su product-builder non verrà duplicata.

## Atomic updater

Il repository conserva due generazioni dell'updater:

- `myslowroll-atomic-dup-v3.4.9-tested.sh` è la baseline operativa collaudata;
- `myslowroll-atomic-dup-v4-tukit-preview.sh` è la preview architetturale v4 basata su `tukit`.

La v4 sposta `zypper dup` fuori dalla root live: una TARGET Btrfs offline viene clonata dalla SOURCE, aggiornata e verificata prima di diventare la snapshot predefinita. La preview **non è ancora un updater di produzione**: i comandi mutanti restano intenzionalmente bloccati finché il flusso completo v3.4.9 non viene ribasato e la matrice crash/recovery non viene validata in VM.

Dettagli, vincoli e criteri di promozione: [`RELEASE-v4.0.6-tukit-preview.md`](RELEASE-v4.0.6-tukit-preview.md).

## Stato

Il materiale proveniente dagli esperimenti precedenti verrà analizzato come insieme di fonti indipendenti. Nessuna vecchia configurazione verrà importata integralmente senza revisione.
