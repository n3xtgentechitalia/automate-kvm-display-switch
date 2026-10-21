<#
.SYNOPSIS
    Passa automaticamente gli schermi in Duplica al blocco del PC e in Estendi al login,
    per usare un KVM-over-IP (es. GL.iNet Comet) collegato come secondo display.

.DESCRIPTION
    Un unico script che si installa, crea le attivita' pianificate e le icone sul desktop,
    e viene richiamato da queste ultime per cambiare la topologia degli schermi.

    - Blocco del PC      -> Duplica  (il KVM vede la schermata di login)
    - Login / sblocco    -> Estendi
    - Icone sul desktop  -> Blocca (duplica), Esci (duplica),
                            Duplica schermi (Ctrl+Alt+D), Estendi schermi (Ctrl+Alt+E)

    Il cambio usa SetDisplayConfig (la stessa API di Win+P); DisplaySwitch.exe resta
    come riserva. Ogni cambio viene verificato, ripetuto fino a 3 volte e registrato in
    %LOCALAPPDATA%\SchermiKVM\schermi-kvm.log.

.PARAMETER Azione
    Cosa fare. Senza parametri apre il menu interattivo.
      Menu         Menu interattivo (predefinito)
      Installa     Installa o aggiorna (richiede amministratore)
      Disinstalla  Rimuove attivita', icone e file (richiede amministratore)
      Stato        Mostra stato, attivita' pianificate e ultime righe del log
      Test         Prova Duplica -> Estendi
      Duplica      Passa in Duplica
      Estendi      Passa in Estendi
      Blocca       Passa in Duplica e blocca il PC
      Esci         Passa in Duplica e disconnette l'utente

.PARAMETER Utente
    Utente per cui registrare le attivita'. Usato internamente durante l'auto-elevazione.

.PARAMETER Desktop
    Cartella Desktop in cui creare le icone. Usato internamente durante l'auto-elevazione.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\schermi-kvm.ps1
    Apre il menu interattivo.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\schermi-kvm.ps1 -Azione Installa
    Installa senza passare dal menu.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\schermi-kvm.ps1 -Azione Duplica
    Passa subito in Duplica.

.NOTES
    Requisiti: Windows 10/11, Windows PowerShell 5.1 o PowerShell 7.
    Licenza:   MIT
#>
#Requires -Version 5.1

param(
    [ValidateSet('Menu','Installa','Disinstalla','Stato','Test','Duplica','Estendi','Blocca','Esci')]
    [string]$Azione  = 'Menu',
    [string]$Utente  = "$env:USERDOMAIN\$env:USERNAME",
    [string]$Desktop = [Environment]::GetFolderPath('Desktop')
)

# ----------------------------- Configurazione -----------------------------
$Versione   = '1.2.0'
$NomeApp    = 'SchermiKVM'
$Cartella   = Join-Path $env:ProgramData $NomeApp
$ScriptDest = Join-Path $Cartella 'schermi-kvm.ps1'
$LogDir     = Join-Path $env:LOCALAPPDATA $NomeApp
$LogFile    = Join-Path $LogDir 'schermi-kvm.log'
$DS         = Join-Path $env:WINDIR 'System32\DisplaySwitch.exe'
$TaskClone  = 'SchermiKVM - Duplica al blocco'
$TaskExt    = 'SchermiKVM - Estendi al login'
$LnkBlocca  = 'Blocca (duplica).lnk'
$LnkEsci    = 'Esci (duplica).lnk'
$LnkDup     = 'Duplica schermi.lnk'
$LnkEst     = 'Estendi schermi.lnk'
$TuttiLnk   = @($LnkBlocca, $LnkEsci, $LnkDup, $LnkEst)
$Tentativi  = 3

# ----------------------------- Utilita' -----------------------------------
function Titolo($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Ok($t)     { Write-Host "  [OK] $t" -ForegroundColor Green }
function Ko($t)     { Write-Host "  [!!] $t" -ForegroundColor Red }
function Info($t)   { Write-Host "       $t" }
function Pausa      { Read-Host "`nPremi Invio per continuare" | Out-Null }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Log($msg) {
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 512KB)) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
        $riga = '{0}  [{1}]  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Azione, $msg
        Add-Content -Path $LogFile -Value $riga
    } catch {
        # Il log non deve mai interrompere un cambio di modalita'
        Write-Debug "Scrittura log non riuscita: $($_.Exception.Message)"
    }
}

# API di Windows:
#  - GetSystemMetrics(SM_CMONITORS): schermi "logici" attivi
#      1 = Duplica (o un solo schermo), 2+ = Estendi
#  - SetDisplayConfig: la stessa chiamata che usa Win+P
if (-not ('SchermiKVM.Native' -as [type])) {
    Add-Type -Namespace SchermiKVM -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
[DllImport("user32.dll")] public static extern int SetDisplayConfig(uint numPathArrayElements, System.IntPtr pathArray, uint numModeInfoArrayElements, System.IntPtr modeInfoArray, uint flags);
'@
}
$SDC_APPLY           = 0x80
$SDC_TOPOLOGY_CLONE  = 0x02
$SDC_TOPOLOGY_EXTEND = 0x04

function Get-NumeroSchermi { return [SchermiKVM.Native]::GetSystemMetrics(80) }   # SM_CMONITORS
function Get-ModalitaTesto {
    $n = Get-NumeroSchermi
    if ($n -ge 2) { return "Estendi ($n schermi)" } else { return 'Duplica / schermo singolo' }
}
function Test-Modalita([string]$Mod) {
    $n = Get-NumeroSchermi
    if ($Mod -eq 'Duplica') { return ($n -le 1) } else { return ($n -ge 2) }
}

# ----------------------------- Cambio modalita' ---------------------------
# Tentativo 1: SetDisplayConfig (API diretta, come Win+P)
# Tentativo 2: DisplaySwitch.exe con argomento numerico (Windows 11 recenti)
# Tentativo 3: DisplaySwitch.exe con argomento classico (/clone, /extend)
function Imposta-Modalita([string]$Mod) {
    if (Test-Modalita $Mod) { Log "Gia' in modalita' $Mod (schermi attivi: $(Get-NumeroSchermi))"; return $true }

    $topo   = if ($Mod -eq 'Duplica') { $SDC_TOPOLOGY_CLONE } else { $SDC_TOPOLOGY_EXTEND }
    $argNum = if ($Mod -eq 'Duplica') { '2' } else { '3' }
    $argOld = if ($Mod -eq 'Duplica') { '/clone' } else { '/extend' }

    for ($i = 1; $i -le $Tentativi; $i++) {
        $metodo = ''
        try {
            switch ($i) {
                1 {
                    $rc = [SchermiKVM.Native]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, [uint32]($SDC_APPLY -bor $topo))
                    $metodo = "SetDisplayConfig (codice $rc)"
                }
                2 { Start-Process -FilePath $DS -ArgumentList $argNum; $metodo = "DisplaySwitch $argNum" }
                default { Start-Process -FilePath $DS -ArgumentList $argOld; $metodo = "DisplaySwitch $argOld" }
            }
        } catch {
            $metodo = "errore: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 3
        $n = Get-NumeroSchermi
        Log "Tentativo $i/$Tentativi -> $Mod via $metodo, schermi attivi: $n"
        if (Test-Modalita $Mod) { Log "Modalita' $Mod applicata"; return $true }
    }
    Log "ATTENZIONE: $Mod non applicata dopo $Tentativi tentativi"
    return $false
}

# ----------------------------- Installazione ------------------------------
function Esegui-Installa {
    Titolo "Installazione per l'utente $Utente"

    if (-not (Test-Path $DS)) { throw "DisplaySwitch.exe non trovato ($DS)" }

    # 1. Copia dello script in una posizione fissa
    New-Item -ItemType Directory -Path $Cartella -Force | Out-Null
    if ($PSCommandPath -ne $ScriptDest) { Copy-Item -Path $PSCommandPath -Destination $ScriptDest -Force }
    Unblock-File -Path $ScriptDest -ErrorAction SilentlyContinue
    Ok "Script installato in $ScriptDest"

    $psArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptDest`" -Azione"

    # 2. Trigger: 7 = blocco sessione, 8 = sblocco sessione
    $cls = Get-CimClass -Namespace ROOT\Microsoft\Windows\TaskScheduler -ClassName MSFT_TaskSessionStateChangeTrigger

    $trgBlocco = New-CimInstance -CimClass $cls -ClientOnly
    $trgBlocco.StateChange = 7; $trgBlocco.UserId = $Utente; $trgBlocco.Enabled = $true

    $trgSblocco = New-CimInstance -CimClass $cls -ClientOnly
    $trgSblocco.StateChange = 8; $trgSblocco.UserId = $Utente; $trgSblocco.Enabled = $true
    $trgSblocco.Delay = 'PT3S'

    $trgLogin = New-ScheduledTaskTrigger -AtLogOn -User $Utente
    $trgLogin.Delay = 'PT5S'

    $principal = New-ScheduledTaskPrincipal -UserId $Utente -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew

    # 3. Attivita' pianificate (richiamano questo script)
    Register-ScheduledTask -TaskName $TaskClone -Trigger $trgBlocco `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "$psArgs Duplica") `
        -Principal $principal -Settings $settings -Description 'Schermi in Duplica al blocco del PC (KVM)' -Force | Out-Null
    Ok "Attivita' '$TaskClone' creata"

    Register-ScheduledTask -TaskName $TaskExt -Trigger @($trgSblocco, $trgLogin) `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "$psArgs Estendi") `
        -Principal $principal -Settings $settings -Description 'Schermi in Estendi al login/sblocco (KVM)' -Force | Out-Null
    Ok "Attivita' '$TaskExt' creata"

    # 4. Icone sul desktop
    $shell = New-Object -ComObject WScript.Shell
    $icone = @(
        @{ Nome = $LnkBlocca; Az = 'Blocca';  Ic = 54;  Tasti = '';           Desc = 'Passa in Duplica e blocca il PC' },
        @{ Nome = $LnkEsci;   Az = 'Esci';    Ic = 100; Tasti = '';           Desc = "Passa in Duplica e disconnette l'utente" },
        @{ Nome = $LnkDup;    Az = 'Duplica'; Ic = 189; Tasti = 'CTRL+ALT+D'; Desc = 'Passa gli schermi in Duplica (Ctrl+Alt+D)' },
        @{ Nome = $LnkEst;    Az = 'Estendi'; Ic = 190; Tasti = 'CTRL+ALT+E'; Desc = 'Passa gli schermi in Estendi (Ctrl+Alt+E)' }
    )
    foreach ($d in $icone) {
        $lnk = $shell.CreateShortcut((Join-Path $Desktop $d.Nome))
        $lnk.TargetPath   = 'powershell.exe'
        $lnk.Arguments    = "$psArgs $($d.Az)"
        $lnk.WindowStyle  = 7
        $lnk.IconLocation = "$env:WINDIR\System32\imageres.dll,$($d.Ic)"
        $lnk.Description  = $d.Desc
        if ($d.Tasti) { $lnk.Hotkey = $d.Tasti }
        $lnk.Save()
        $extra = if ($d.Tasti) { " (tasti: $($d.Tasti))" } else { '' }
        Ok "Icona '$($d.Nome)' creata sul desktop$extra"
    }

    Log "Installazione $Versione completata per $Utente"

    # 5. Verifica e test
    Esegui-Stato
    Esegui-Test

    Titolo 'Fatto'
    Info 'Prova finale: premi Win+L e controlla dalla console del KVM che si veda il login.'
    Info "Se il KVM resta nero al blocco, usa l'icona 'Blocca (duplica)' sul desktop."
    Info 'Scorciatoie: Ctrl+Alt+D = Duplica, Ctrl+Alt+E = Estendi (attive dal prossimo login).'
}

# ----------------------------- Disinstallazione ---------------------------
function Esegui-Disinstalla {
    Titolo 'Disinstallazione'
    foreach ($t in @($TaskClone, $TaskExt)) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
            Ok "Rimossa attivita' '$t'"
        }
    }
    foreach ($l in $TuttiLnk) {
        $p = Join-Path $Desktop $l
        if (Test-Path $p) { Remove-Item $p -Force; Ok "Rimossa icona '$l'" }
    }
    if (Test-Path $Cartella) { Remove-Item $Cartella -Recurse -Force; Ok "Rimossa cartella $Cartella" }
    if ((Read-Host 'Cancellare anche il log? (s/n)') -match '^[sSyY]') {
        if (Test-Path $LogDir) { Remove-Item $LogDir -Recurse -Force; Ok 'Log rimosso' }
    }
    if (Imposta-Modalita 'Estendi') { Ok 'Schermi riportati in Estendi' }
}

# ----------------------------- Stato --------------------------------------
function Esegui-Stato {
    Titolo 'Stato'
    Info "Modalita' attuale: $(Get-ModalitaTesto)"
    if (Test-Path $ScriptDest) { Ok "Script installato ($ScriptDest)" } else { Ko 'Script non installato' }

    foreach ($t in @($TaskClone, $TaskExt)) {
        $s = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        if ($s) {
            $i = Get-ScheduledTaskInfo -TaskName $t
            $ultimo = if ($i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { $i.LastRunTime } else { 'mai' }
            Ok "'$t' [$($s.State)] - ultima esecuzione: $ultimo, risultato: $($i.LastTaskResult)"
        } else { Ko "'$t' non trovata" }
    }
    foreach ($l in $TuttiLnk) {
        if (Test-Path (Join-Path $Desktop $l)) { Ok "Icona '$l' presente" } else { Ko "Icona '$l' mancante" }
    }
    if (Test-Path $LogFile) {
        Info ''
        Info 'Ultime righe del log:'
        Get-Content $LogFile -Tail 10 | ForEach-Object { Info $_ }
    }
}

# ----------------------------- Test ---------------------------------------
function Esegui-Test {
    Titolo "Test cambio modalita'"
    Info 'Gli schermi passano in Duplica per 5 secondi, poi tornano in Estendi.'
    if ((Read-Host 'Procedo? (s/n)') -notmatch '^[sSyY]') { return }
    if (Imposta-Modalita 'Duplica') { Ok 'Duplica OK' } else { Ko 'Duplica non riuscita (vedi log)' }
    Start-Sleep -Seconds 5
    if (Imposta-Modalita 'Estendi') { Ok 'Estendi OK' } else { Ko 'Estendi non riuscita (vedi log)' }
}

# ----------------------------- Elevazione ---------------------------------
function Avvia-Elevato([string]$Az) {
    if (Test-Admin) {
        try { & "Esegui-$Az" } catch { Ko "Errore: $($_.Exception.Message)"; Log "Errore $Az : $($_.Exception.Message)" }
        Pausa
    } else {
        Write-Host 'Richiedo i privilegi di amministratore...' -ForegroundColor Yellow
        $a = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Azione $Az -Utente `"$Utente`" -Desktop `"$Desktop`""
        try   { Start-Process powershell.exe -Verb RunAs -ArgumentList $a }
        catch { Ko 'Privilegi di amministratore negati.'; Pausa }
    }
}

# ----------------------------- Menu ---------------------------------------
function Mostra-Menu {
    while ($true) {
        Clear-Host
        Write-Host "SchermiKVM $Versione - Duplica/Estendi automatico per KVM" -ForegroundColor Cyan
        Write-Host "Modalita' attuale: $(Get-ModalitaTesto)"
        Write-Host ''
        Write-Host '  1  Installa / aggiorna'
        Write-Host '  2  Stato e log'
        Write-Host '  3  Test (Duplica -> Estendi)'
        Write-Host '  4  Disinstalla'
        Write-Host '  0  Esci'
        switch (Read-Host "`nScelta") {
            '1' { Avvia-Elevato 'Installa';    return }
            '2' { Esegui-Stato; Pausa }
            '3' { Esegui-Test;  Pausa }
            '4' { Avvia-Elevato 'Disinstalla'; return }
            '0' { return }
        }
    }
}

# ----------------------------- Avvio --------------------------------------
switch ($Azione) {
    'Menu'        { Mostra-Menu }
    'Installa'    { Avvia-Elevato 'Installa' }
    'Disinstalla' { Avvia-Elevato 'Disinstalla' }
    'Stato'       { Esegui-Stato; Pausa }
    'Test'        { Esegui-Test;  Pausa }
    'Duplica'     { Imposta-Modalita 'Duplica' | Out-Null }
    'Estendi'     { Imposta-Modalita 'Estendi' | Out-Null }
    'Blocca'      { Imposta-Modalita 'Duplica' | Out-Null; Start-Sleep -Seconds 1; rundll32.exe user32.dll,LockWorkStation }
    'Esci'        { Imposta-Modalita 'Duplica' | Out-Null; Start-Sleep -Seconds 1; shutdown.exe /l }
}
