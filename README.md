# mySlowrollOS

Workstation personale, minimale e riproducibile basata su **openSUSE Slowroll**, Plasma Wayland, Btrfs e Snapper.

L'obiettivo non è creare un fork di Slowroll, ma descrivere e costruire tramite Open Build Service un sistema resistente alle modifiche accidentali.

## Decisioni fissate

- base: openSUSE Slowroll;
- desktop: Plasma su Wayland;
- Xwayland incluso per la compatibilità con applicazioni legacy;
- nessuna sessione Plasma X11 e nessun server Xorg completo;
- partizionamento scelto interattivamente nell'installer grafico;
- `/home` su partizione separata, riutilizzabile senza formattarla;
- root Btrfs con Snapper e integrazione ZYpp;
- AppArmor; nessuna policy SELinux attiva;
- YaST grafico mantenuto finché disponibile;
- niente installazione automatica delle dipendenze raccomandate;
- pacchetti necessari all'uso normale dichiarati esplicitamente;
- un RPM `myslowroll-core` proteggerà il nucleo dalla rimozione accidentale;
- applicazioni e accessori non essenziali resteranno rimovibili.

Il profilo di build non imporrà uno schema di partizionamento né formatterà automaticamente `/home`.

## Build

L'utente OBS del progetto è `krism`. OBS userà direttamente i repository di `openSUSE:Slowroll`.

Il progetto avrà inizialmente due soli componenti:

1. `myslowroll-core`: metapacchetto RPM con le dipendenze indispensabili e una protezione esplicita dalla disinstallazione accidentale;
2. `myslowroll-image`: descrizione dichiarativa della workstation e immagine di verifica.

Il formato dell'immagine installabile va scelto senza perdere il partizionatore grafico. Una semplice ISO live KIWI e una ISO OEM KIWI non equivalgono al DVD di installazione YaST: la seconda distribuisce un'immagine disco predefinita. Valuteremo quindi un media con installer interattivo, mantenendo separata l'immagine KIWI usata per verificare in modo riproducibile la selezione dei pacchetti.

La pipeline ufficiale del DVD Slowroll basata su product-builder non verrà duplicata finché non sarà dimostrato che serve davvero.

## Stato

Il materiale proveniente dagli esperimenti precedenti verrà analizzato come insieme di fonti indipendenti. Nessuna vecchia configurazione verrà importata integralmente senza revisione.
