# Protezione con `criscore1` e `criscore2`

## Scopo

`criscore1` e `criscore2` sostituiscono lo “scudo” offerto dai pattern generici
openSUSE e KDE, senza importarli e senza ereditarne il contenuto sovrabbondante.

Sono metapacchetti: non contengono copie delle applicazioni e non installano due
volte nulla. Entrambi dichiarano lo stesso insieme di dipendenze; RPM/Zypper
installa una sola istanza di ciascun pacchetto richiesto.

## Struttura concordata

Un solo progetto sorgente genera due RPM binari:

- `criscore1`;
- `criscore2`.

Entrambi ricevono lo stesso elenco approvato di `Requires`. In aggiunta:

- `criscore1` richiede la stessa versione-release di `criscore2`;
- `criscore2` richiede la stessa versione-release di `criscore1`.

L'elenco comune avrà una sola fonte modificabile. Lo spec generato ripeterà
materialmente i `Requires` nei due sottopacchetti, evitando che le due liste
possano divergere.

## Cosa protegge davvero

Se si tenta di rimuovere un pacchetto richiesto, il solver deve proporre anche la
rimozione di entrambe le ancore. La dipendenza circolare rende evidente
l'operazione e impedisce di eliminare una sola ancora lasciando l'altra.

Ogni ancora avrà inoltre un controllo `%preun`:

- gli aggiornamenti del pacchetto sono consentiti;
- una disinstallazione reale viene rifiutata;
- la rimozione volontaria richiede la creazione preventiva di un file di
  sblocco sotto `/run`.

Questo protegge dagli errori nelle normali operazioni Zypper/RPM. Non pretende di
fermare root che usi `rpm --nodeps`, cancelli file manualmente o modifichi lo
spec: non è immutabilità e non è atomicità.

## Contenuto del core

Non si importano automaticamente pacchetti dalle vecchie liste. Le liste
storiche restano un memorandum per individuare funzioni dimenticate.

Il manifesto verrà costruito per funzioni osservabili:

1. avvio e Secure Boot;
2. RPM/Zypper e identità Slowroll;
3. root Btrfs, Snapper e ripristino;
4. rete necessaria alla macchina;
5. firmware e input necessari alla macchina;
6. audio essenziale;
7. sessione Plasma Wayland realmente avviabile, inclusi i componenti necessari
   al greeter;
8. amministrazione grafica essenziale scelta esplicitamente.

Applicazioni aggiungibili in seguito, strumenti occasionali e funzioni non
usate sulla macchina non entrano nel core solo perché comparivano in una
vecchia installazione.

## Locale oppure OBS

### Fase di sviluppo: repository locale

È la scelta iniziale:

- ciclo modifica/build/test rapido;
- nessuna pubblicazione di prove;
- i due RPM vengono installati o aggiornati nella stessa transazione;
- un piccolo repository locale è preferibile a due file RPM sciolti, perché
  Zypper conserva una sorgente aggiornabile.

Comando concettuale per la prima installazione:

```sh
sudo zypper install criscore1 criscore2
```

Il comando concreto dipenderà dal percorso e dalla firma del repository locale.

### Fase stabile: OBS

Quando il manifesto è approvato, OBS diventa utile:

- costruisce entrambi i binari dallo stesso sorgente;
- pubblica un repository firmato;
- segnala quando una dipendenza non è più risolvibile;
- rende più semplice reinstallare e aggiornare la coppia.

OBS non sceglie il sostituto di un pacchetto rinominato: quel cambiamento resta
una decisione nostra. Per questo non conviene pubblicare la selezione ancora
mobile.

Decisione proposta: **locale durante la definizione; OBS quando il core supera i
test in VM e sulla macchina**.

## Installazione del sistema

La protezione è indipendente dal modo con cui nasce il sistema. Il percorso
proposto è:

1. KIWI risolve e valida le liste `system` e `plasma`;
2. decidiamo il sottoinsieme realmente da proteggere;
3. generiamo e testiamo localmente `criscore1` e `criscore2`;
4. il profilo d'installazione installa le liste approvate e le due ancore;
5. il partizionamento resta interattivo, così `/home` separata può essere
   selezionata e conservata;
6. solo dopo scegliamo se distribuire il profilo tramite supporto per Agama o
   incorporarlo in una ISO KIWI personalizzata.

Il metapacchetto non deve coincidere con l'intero profilo d'installazione:
quest'ultimo può includere software utile ma liberamente rimovibile.

## Prossimo passo

Prima di scrivere lo spec definitivo occorre produrre tre elenchi separati:

- `system.seed`: ciò che deve essere installato nel sistema;
- `plasma.seed`: desktop e applicazioni installate;
- `protected.seed`: solo ciò che non deve essere rimosso accidentalmente.

`protected.seed` sarà l'unica fonte per i `Requires` comuni delle due ancore.
