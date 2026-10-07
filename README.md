# mySlowrollOS — recovered baseline

Repository di scambio per ricostruire e completare mySlowrollOS.

Questo repository riparte dal materiale recuperato del 28 settembre 2026 senza dichiararlo definitivo.

Architettura recuperata:
- `myslowroll-workstation`: manifest software della workstation;
- `myslowroll-policy`: policy statiche persistenti;
- `agama-product-myslowroll`: prodotto Agama recuperato, da riesaminare;
- `agama/post-install.sh`: operazioni stateful/post-install recuperate;
- `atomic-update`: updater separato, da rivalutare prima di un eventuale 5.7;
- KIWI: artefatti di composizione/verifica, non fonte primaria dell'installazione reale.

Prima di cambiare architettura, confrontare il materiale recuperato con i pacchetti effettivamente presenti in OBS `home:krism`.

Obiettivo immediato: ricostruire un profilo Agama remoto e verificabile, mantenendo l'installazione sotto controllo e risolvendo correttamente repository/GPG, software, storage e post-install.
