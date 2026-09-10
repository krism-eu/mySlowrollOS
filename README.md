# mySlowrollOS

Configurazione personale, minimale e riproducibile basata su **openSUSE Slowroll**, Plasma Wayland, Btrfs e Snapper.

L'obiettivo non è creare una distribuzione pubblica, ma descrivere un'installazione resistente alle modifiche accidentali per una sola macchina.

## Decisioni fissate

- base: openSUSE Slowroll;
- installazione dalla ISO ufficiale di Agama;
- profilo Agama dichiarativo, inizialmente ricavato dagli XML AutoYaST già provati;
- partizionamento scelto interattivamente nell'installer;
- `/home` su partizione separata, riutilizzata senza formattarla;
- desktop: Plasma su Wayland;
- Xwayland incluso per la compatibilità con applicazioni legacy;
- nessuna sessione Plasma X11 e nessun server Xorg completo;
- root Btrfs con Snapper e integrazione ZYpp;
- AppArmor; nessuna policy SELinux attiva;
- YaST grafico mantenuto finché disponibile;
- niente installazione automatica delle dipendenze raccomandate;
- pacchetti necessari all'uso normale dichiarati esplicitamente;
- un RPM locale `myslowroll-core` proteggerà il nucleo dalla rimozione accidentale;
- applicazioni e accessori non essenziali resteranno rimovibili.

Il profilo non imporrà uno schema di partizionamento e non formatterà automaticamente `/home`.

## Percorso minimo

1. costruire con KIWI una baseline Slowroll partendo da pacchetti radice espliciti e `onlyRequired`, senza pattern desktop;
2. confrontare la chiusura reale delle dipendenze prodotta da KIWI con le liste degli esperimenti precedenti;
3. scegliere insieme quali pacchetti appartengono al core protetto e quali soltanto al profilo d'installazione;
4. generare un profilo Agama parziale e modificabile, senza sezione `storage`;
5. installare con la ISO Agama ufficiale scegliendo il disco manualmente, oppure produrre successivamente una ISO personalizzata;
6. costruire e installare localmente `myslowroll-core.rpm` solo dopo l'approvazione della selezione;
7. verificare aggiornamento, rollback Snapper e tentativi di rimozione in VM.

OBS non è necessario per la prima versione. L'account `krism` resta disponibile per eventuali build remote, controlli periodici o per pubblicare in seguito il pacchetto, ma il metapacchetto può rimanere esclusivamente locale. OBS segnala dipendenze non più risolvibili, ma non corregge automaticamente pacchetti rinominati.

## Stato

Il materiale proveniente dagli esperimenti precedenti viene trattato come insieme di fonti indipendenti. Nessuna vecchia configurazione sarà importata integralmente senza revisione.
