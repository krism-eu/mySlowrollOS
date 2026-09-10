# mySlowrollOS

Configurazione personale, minimale e riproducibile basata su **openSUSE Slowroll**, Plasma Wayland, Btrfs e Snapper.

L'obiettivo non è creare una distribuzione pubblica, ma descrivere un'installazione resistente alle modifiche accidentali per una sola macchina.

## Decisioni fissate

- base: openSUSE Slowroll;
- partizionamento scelto interattivamente nell'installer;
- `/home` su partizione separata, riutilizzata senza formattarla;
- desktop: Plasma su Wayland;
- Xwayland incluso per la compatibilità con applicazioni legacy;
- nessuna sessione Plasma X11;
- root Btrfs con Snapper e integrazione ZYpp;
- AppArmor; nessuna policy SELinux attiva;
- YaST grafico mantenuto finché disponibile;
- niente installazione automatica delle dipendenze raccomandate;
- pacchetti necessari all'uso normale dichiarati esplicitamente;
- due metapacchetti locali, `criscore1` e `criscore2`, proteggeranno lo stesso nucleo e si richiederanno reciprocamente;
- applicazioni e accessori non essenziali resteranno rimovibili.

Il profilo non imporrà uno schema di partizionamento e non formatterà automaticamente `/home`.

## Percorso minimo

1. risolvere con KIWI/Zypper una baseline Slowroll partendo da pacchetti radice espliciti e `onlyRequired`, senza pattern desktop;
2. confrontare la chiusura reale delle dipendenze con le liste degli esperimenti precedenti;
3. distinguere ciò che è installato da ciò che deve essere protetto;
4. generare dallo stesso manifesto `criscore1` e `criscore2`;
5. provarli da un repository locale;
6. scegliere il supporto di installazione mantenendo il partizionamento interattivo;
7. pubblicare eventualmente su OBS solo dopo la stabilizzazione;
8. verificare aggiornamento, rollback Snapper e tentativi di rimozione in VM.

La progettazione della coppia di protezione è descritta in [core/README.md](core/README.md).

## Stato

Il materiale proveniente dagli esperimenti precedenti viene trattato come insieme di fonti indipendenti. Nessuna vecchia configurazione sarà importata integralmente senza revisione.
