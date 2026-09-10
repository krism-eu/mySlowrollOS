# KIWI workstation

Questa directory contiene la descrizione KIWI della workstation personale
Slowroll.

Il primo target e `tbz`: costruisce l'intero root filesystem e lo impacchetta in
un archivio, senza creare una tabella partizioni e senza imporre alcuna scelta a
`/home`. Serve a validare con KIWI la stessa selezione gia provata con Zypper:
`system.seed` + `plasma.seed` + `criscore1` + `criscore2`.

`workstation/config.xml` e generato da:

```sh
bash kiwi/generate-workstation-config
```

Per la build locale, dentro un ambiente Tumbleweed con privilegi sufficienti:

```sh
zypper in rpm-build createrepo_c python3-kiwi
bash kiwi/build-workstation-rootfs
```

Lo script ricostruisce i due criscore, crea un repository RPM-MD locale sotto
`out/criscore-repo/`, rigenera `config.xml` e avvia KIWI. I risultati restano
sotto `out/kiwi-workstation-rootfs/`.

Durante lo sviluppo i due RPM locali non sono firmati, quindi questa prima
descrizione disabilita il controllo firma RPM. Quando `criscore1`/`criscore2`
saranno pubblicati nel repository personale OBS, il repository locale verra
sostituito con quello OBS e il controllo firma verra riattivato.

Questo target non e ancora il supporto finale d'installazione. Il passaggio
successivo, dopo la validazione del rootfs KIWI, e costruire il mezzo avviabile
senza codificare un layout disco: il partizionamento finale deve restare
interattivo e permettere il riuso di `/home` senza formattazione.
