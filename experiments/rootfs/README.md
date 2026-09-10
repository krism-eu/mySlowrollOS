# Esperimento rootfs Slowroll da zero

Questo esperimento misura la chiusura delle dipendenze partendo da una directory
vuota. Il container Tumbleweed fornisce soltanto l'eseguibile `zypper`: tutti i
repository e tutti gli RPM installati nel target sono di Slowroll.

`stage0.seed` non descrive ancora un sistema avviabile completo. Serve a
misurare il pavimento del solver prima di aggiungere bootloader, Btrfs/Snapper,
rete, AppArmor, YaST e Plasma.

## Esecuzione

Requisiti sull'host:

- Podman oppure Docker;
- almeno 8 GiB liberi;
- esecuzione dalla radice del repository.

```sh
./experiments/rootfs/measure.sh stage0
```

Lo script non cancella né riutilizza una root precedente. Ogni esecuzione crea
`out/stage0-<data>/` contenente:

- `rootfs/`: sistema installato;
- `report/seeds.txt`: pacchetti richiesti esplicitamente;
- `report/installed.tsv`: chiusura completa con versioni, architetture e
  dimensioni RPM installate;
- `report/installed.names`: soli nomi dei pacchetti;
- `report/unneeded.txt`: ciò che Zypper considera non necessario;
- `report/summary.txt`: conteggio e spazio occupato.

La directory `out/` deve restare fuori da Git. Nel repository entreranno
soltanto i seed approvati e i report testuali utili al confronto.

## Regola di interpretazione

Un pacchetto presente in `installed.tsv` non diventa automaticamente parte del
metapacchetto. Il metapacchetto conterrà i seed funzionali approvati; le loro
dipendenze continueranno a essere risolte da libsolv.
