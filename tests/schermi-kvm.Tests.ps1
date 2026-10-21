#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Test statici: analizzano lo script con il parser di PowerShell senza eseguirlo,
    quindi girano su qualsiasi runner (anche senza secondo schermo) e non toccano il sistema.
#>

BeforeDiscovery {
    $script:FunzioniAttese = @(
        'Imposta-Modalita', 'Test-Modalita', 'Get-NumeroSchermi', 'Get-ModalitaTesto',
        'Esegui-Installa', 'Esegui-Disinstalla', 'Esegui-Stato', 'Esegui-Test',
        'Avvia-Elevato', 'Mostra-Menu', 'Log', 'Test-Admin'
    )
}

BeforeAll {
    $script:Percorso = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') 'schermi-kvm.ps1')).Path
    $tokens = $null
    $errori = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:Percorso, [ref]$tokens, [ref]$errori)
    $script:ErroriSintassi = $errori

    $script:Funzioni = $script:Ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | ForEach-Object Name

    $param = $script:Ast.ParamBlock.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -eq 'Azione' }
    $validateSet = $param.Attributes |
        Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
    $script:AzioniDichiarate = $validateSet.PositionalArguments | ForEach-Object Value

    # Lo switch finale ($Azione) e' l'ultimo SwitchStatementAst di primo livello
    $switch = $script:Ast.EndBlock.Statements |
        Where-Object { $_ -is [System.Management.Automation.Language.SwitchStatementAst] } |
        Select-Object -Last 1
    $script:AzioniGestite = $switch.Clauses | ForEach-Object { $_.Item1.Value }

    $script:Testo = Get-Content -Path $script:Percorso -Raw
}

Describe 'schermi-kvm.ps1' {

    Context 'Sintassi e codifica' {
        It 'non contiene errori di sintassi' {
            $script:ErroriSintassi | Should -BeNullOrEmpty
        }

        It 'contiene solo caratteri ASCII (compatibilita'' con PowerShell 5.1 senza BOM)' {
            $nonAscii = [System.IO.File]::ReadAllBytes($script:Percorso) | Where-Object { $_ -gt 127 }
            $nonAscii | Should -BeNullOrEmpty
        }

        It 'dichiara la versione minima di PowerShell' {
            $script:Ast.ScriptRequirements.RequiredPSVersion | Should -Be ([version]'5.1')
        }

        It 'ha un help integrato con SYNOPSIS' {
            $script:Ast.GetHelpContent().Synopsis | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Struttura' {
        It 'definisce la funzione <_>' -ForEach $script:FunzioniAttese {
            $script:Funzioni | Should -Contain $_
        }

        It 'gestisce nello switch finale tutte le azioni dichiarate in ValidateSet' {
            $script:AzioniDichiarate | Should -Not -BeNullOrEmpty
            Compare-Object $script:AzioniDichiarate $script:AzioniGestite | Should -BeNullOrEmpty
        }

        It 'ha una funzione Esegui-<_> per ogni azione che richiede elevazione' -ForEach @('Installa', 'Disinstalla') {
            $script:Funzioni | Should -Contain "Esegui-$_"
        }

        It 'dichiara una versione semantica' {
            $script:Testo | Should -Match "\`$Versione\s*=\s*'\d+\.\d+\.\d+'"
        }
    }

    Context 'Sicurezza' {
        It 'non usa Invoke-Expression' {
            $script:Testo | Should -Not -Match '(?i)\bInvoke-Expression\b|\biex\b'
        }

        It 'non effettua richieste di rete' {
            $script:Testo | Should -Not -Match '(?i)Invoke-WebRequest|Invoke-RestMethod|Net\.WebClient|Start-BitsTransfer'
        }

        It 'non modifica il criterio di esecuzione di sistema' {
            $script:Testo | Should -Not -Match '(?i)Set-ExecutionPolicy'
        }

        It 'registra le attivita'' pianificate senza privilegi elevati' {
            $script:Testo | Should -Match '-RunLevel Limited'
            $script:Testo | Should -Not -Match '-RunLevel Highest'
        }
    }
}
