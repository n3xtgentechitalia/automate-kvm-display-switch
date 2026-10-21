# Changelog

Tutte le modifiche rilevanti a questo progetto sono documentate in questo file.

Il formato segue [Keep a Changelog](https://keepachangelog.com/it-IT/1.1.0/)
e il progetto adotta il [Semantic Versioning](https://semver.org/lang/it/).

## [1.2.0] - 2026-10-21

### Aggiunto
- Icone **Duplica schermi** (`Ctrl+Alt+D`) ed **Estendi schermi** (`Ctrl+Alt+E`) sul desktop.
- Help integrato (`Get-Help .\schermi-kvm.ps1 -Full`).
- Numero di versione mostrato nel menu e registrato nel log.
- Test Pester, configurazione PSScriptAnalyzer e workflow di CI.

### Modificato
- Disinstallazione e stato gestiscono anche le nuove icone.
- Gli errori di scrittura del log vengono segnalati in debug invece di essere ignorati.

## [1.1.0] - 2026-10-21

### Modificato
- Il cambio di modalità usa `SetDisplayConfig` (stessa API di Win+P) come metodo principale.
  `DisplaySwitch.exe` resta come riserva, con argomenti numerici (`2`/`3`) e poi classici
  (`/clone`/`/extend`).
- Se la modalità richiesta è già attiva, lo script non esegue alcun cambio.
- Il log riporta il metodo usato e il codice di ritorno di `SetDisplayConfig`.

### Corretto
- Su Windows 11 recenti `DisplaySwitch.exe /clone` e `/extend` non cambiavano modalità.

## [1.0.0] - 2026-10-21

### Aggiunto
- Prima versione: script unico con auto-installazione in `C:\ProgramData\SchermiKVM`.
- Attività pianificate: Duplica al blocco, Estendi a sblocco e login.
- Icone **Blocca (duplica)** ed **Esci (duplica)**.
- Menu interattivo (installa, stato, test, disinstalla) e auto-elevazione.
- Verifica dopo ogni cambio, fino a 3 tentativi, log con rotazione a 512 KB.

[1.2.0]: https://github.com/OWNER/kvm-display-switch/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/OWNER/kvm-display-switch/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/OWNER/kvm-display-switch/releases/tag/v1.0.0
