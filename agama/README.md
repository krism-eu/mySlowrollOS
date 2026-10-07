# Profilo personale Agama

Questa directory contiene solo l'overlay software personale per l'installazione
interattiva di openSUSE Slowroll con Agama.

## Obiettivo

Agama deve continuare a gestire in modo interattivo:

- disco e partizioni;
- filesystem e mount point;
- bootloader;
- rete;
- lingua, tastiera e fuso orario;
- utente e password.

Il profilo personale modifica esclusivamente la selezione software.

`personal-software.json` imposta:

- `patterns: []`: non installare i pattern opzionali predefiniti del prodotto;
- `packages: [criscore1, criscore2]`: i due RPM personali pubblicati su OBS;
- repository OBS `home:krism/openSUSE_Slowroll`;
- `onlyRequired: true`: niente dipendenze raccomandate/suggerite.

Le dipendenze necessarie al sistema devono essere dichiarate nei due RPM OBS.
In questo modo il contratto software vive nei pacchetti, non viene duplicato
nell'installer.

## Uso consigliato

1. Avvia una ISO Agama che supporta Slowroll.
2. Nell'interfaccia seleziona il prodotto Slowroll.
3. Apri una console root.
4. Esegui:

```bash
curl -fsSL https://raw.githubusercontent.com/krism-eu/mySlowrollOS/main/agama/load-personal-profile.sh | bash
```

5. Torna alla GUI Agama e configura normalmente storage, utente e localizzazione.
6. Controlla il riepilogo software prima di installare.

## Perche non usare `inst.auto`

`inst.auto` e pensato per una configurazione di installazione automatica completa.
Qui non vogliamo imporre o precompilare storage e identita utente.

`agama config load` accetta invece una configurazione parziale: le sezioni non
presenti nel JSON non vengono modificate. Questo permette di caricare soltanto
la selezione software e continuare con la GUI.

## Invarianti

- nessun `storage` nel profilo personale;
- nessun `user` o `root`;
- nessuna localizzazione;
- nessuna password;
- nessun pattern desktop;
- niente `Recommends` tramite `onlyRequired: true`;
- niente lista duplicata di centinaia di pacchetti nell'installer.

Se cambia il contenuto del sistema base, si aggiornano gli RPM OBS
`criscore1` / `criscore2`, non il profilo Agama.
