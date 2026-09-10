# Analisi workstation 2026-09-10

Risoluzione effettuata sui repository Slowroll con 136 seed, senza pattern e
senza pacchetti raccomandati.

## Risultato

- pacchetti proposti: 1326;
- download previsto: 1.050.154.616 byte;
- spazio installato previsto: 2.940.067.114 byte;
- riavvio richiesto per il kernel.

Il lock completo è in `locks/workstation-20260910.names`.

## Confronto con la vecchia risoluzione

La precedente prova conteneva 1503 pacchetti. Il nuovo insieme:

- elimina 233 pacchetti della vecchia chiusura;
- introduce 56 pacchetti, principalmente per hardware reale, AppArmor,
  Slowroll, SDDM Qt6 e amministrazione grafica;
- riduce il totale di 177 pacchetti.

Sono assenti:

- `xorg-x11-server`, `xinit`, `plasma6-session-x11`, `kwin6-x11`;
- `sddm`, `sddm-greeter-qt5` e il vecchio branding SDDM;
- policy e strumenti SELinux;
- PackageKit e relativo backend ZYpp;
- Firefox e applicazioni non ancora approvate;
- `yast2-installation`, che appartiene all'installer.

Sono presenti per dipendenza ma non rappresentano servizi indesiderati:

- librerie X11 necessarie a Xwayland e alla compatibilità applicativa;
- librerie Samba richieste dal client CIFS/KIO, senza server Samba;
- `libselinux1` come ABI, senza policy SELinux;
- componenti Qt 5 necessari alla compatibilità di alcune applicazioni;
- ModemManager/WWAN introdotti dall'integrazione di rete Plasma.

`plasma6-desktop` viene risolto anche senza essere un seed esplicito: è parte
della chiusura funzionale Plasma e non un pattern desktop openSUSE.

## Prossime decisioni per macro-componenti

1. tenere stampa e scansione nel profilo desktop o spostarle in un livello
   personale;
2. decidere quali utilità e applicazioni delle vecchie liste aggiungere;
3. valutare se accettare ModemManager/WWAN come dipendenza di `plasma6-nm`;
4. risolvere separatamente `system.seed` per misurare il delta Plasma;
5. solo dopo costruire e avviare la prima immagine KIWI.
