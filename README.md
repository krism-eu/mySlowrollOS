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

## Stato

Il materiale proveniente dagli esperimenti precedenti verrà analizzato come insieme di fonti indipendenti. Nessuna vecchia configurazione verrà importata integralmente senza revisione.

## Prerequisito architetturale di Atomic Dup v4

Atomic Dup v4 richiede che la root attiva sia una **snapshot-root RW numerata**,
montata come `/.snapshots/N/snapshot`, e che la stessa snapshot sia anche il
subvolume Btrfs predefinito. È, per esempio, lo stato in cui resta la workstation
dopo un `snapper rollback` seguito dal reboot previsto.

Una installazione Slowroll classica avviata direttamente da `subvol=/@` non è
compatibile con il motore v4 e il preflight deve rifiutarla esplicitamente. Non è
un dettaglio di parsing: l'identità numerica e l'uguaglianza `ACTIVE == DEFAULT`
sono parte del modello di recovery. La v3.4.9 collaudata applica già questa
invariante; v4 la conserva.

La v4 resta una preview di progetto e non sostituisce la v3.4.9 finché non supera
la matrice crash/recovery in VM.
