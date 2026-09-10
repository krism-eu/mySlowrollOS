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

La protezione vale anche lungo i `Requires` forti transitivi. Non è quindi
necessario elencare ogni libreria. Devono invece essere dichiarati direttamente
i componenti indispensabili che arriverebbero soltanto come `Recommends`, come
provider sostituibili o per integrazione runtime. Tra questi rientrano firmware,
plugin Snapper/Zypper, bridge PipeWire, portali KDE, input del greeter, KWallet e
integrazioni di rete/Bluetooth. Prima del rilascio, un audit del solver proverà
la rimozione simulata dei nodi critici e dovrà vedere entrambe le ancore nella
transazione proposta.

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

## Pulizia protetta dei pacchetti non necessari

Il prototipo [`criscore-clean-orphans`](criscore-clean-orphans) applica tre
controlli:

1. richiede che entrambe le ancore siano installate;
2. esclude esplicitamente `criscore1` e `criscore2` dall'elenco restituito da
   `zypper packages --unneeded`;
3. esegue un `remove --dry-run --clean-deps` e annulla tutto se la sezione
   `<to-remove>` del piano XML contiene una delle due ancore.

Finché le ancore restano installate, le loro dipendenze non sono orfane per il
solver. Il filtro e la simulazione sono controlli ulteriori; il `%preun` dei due
RPM rimane l'ultima barriera. Lo script verrà installato con permessi eseguibili
dal pacchetto definitivo.

## Profilo Agama online e ISO

Agama può caricare un profilo remoto JSON, Jsonnet o AutoYaST tramite URL. Il
profilo può dichiarare:

- i pacchetti `criscore1` e `criscore2`;
- `onlyRequired: true`;
- un repository RPM aggiuntivo mediante `software.extraRepositories`.

L'URL del profilo non sostituisce il repository: Agama scarica il profilo da un
URL, ma i due RPM devono trovarsi in un repository RPM indicizzato, locale o
online. Quando saranno su OBS, il profilo potrà puntare direttamente al
repository firmato.

Per caricare la configurazione senza iniziare automaticamente l'installazione,
il supporto di avvio previsto da Agama è concettualmente:

```text
inst.auto=https://…/profile.json inst.install=0
```

`inst.install=0` è essenziale nel nostro caso: consente di controllare e
modificare graficamente il partizionamento, soprattutto il riuso di `/home`,
prima di avviare l'installazione.

Decisione proposta:

- metodo principale: ISO Agama ufficiale + profilo remoto versionato +
  repository OBS firmato;
- ISO KIWI personalizzata: seconda modalità, utile per installazione offline,
  congelamento di una versione verificata dell'installer o personalizzazioni
  necessarie già nell'ambiente live.

Per una sola macchina non conviene mantenere subito una ISO se il percorso
online supera una reinstallazione completa in VM e riconosce rete, dischi,
Secure Boot e `/home` come previsto.

## Politica degli aggiornamenti

La macchina resta tradizionale e consente installazioni o rimozioni mirate
durante la sessione. Il cambio completo di snapshot Slowroll segue invece una
regola diversa:

- niente `zypper dup` applicato direttamente al sistema in esecuzione;
- il `dup` viene eseguito tramite `transactional-update` in una nuova snapshot;
- il nuovo stato diventa attivo soltanto al riavvio;
- dopo aver preparato la snapshot non si effettuano altre modifiche RPM prima
  del riavvio, per non creare divergenze;
- `/var` deve restare fuori dalla snapshot della root, mentre `/home` continua
  a essere una partizione separata.

Questa è atomicità dell'upgrade completo, non immutabilità quotidiana. Il
comando definitivo verrà racchiuso in uno script dedicato e testato in VM prima
di impedire o scoraggiare il `dup` tradizionale.
