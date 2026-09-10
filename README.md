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

1. ripulire e convertire la selezione software in un profilo parziale per Agama;
2. installare Slowroll con la ISO Agama ufficiale, scegliendo il disco manualmente;
3. costruire e installare localmente `myslowroll-core.rpm`;
4. verificare aggiornamento, rollback Snapper e tentativi di rimozione in VM;
5. usare OBS o costruire una ISO personalizzata soltanto se emerge un vantaggio concreto.

OBS non è necessario per la prima versione. L'account `krism` resta disponibile per eventuali build remote o per pubblicare in seguito il pacchetto, ma il metapacchetto può rimanere esclusivamente locale.

## Stato

Il materiale proveniente dagli esperimenti precedenti viene trattato come insieme di fonti indipendenti. Nessuna vecchia configurazione sarà importata integralmente senza revisione.
