@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # Le funzioni usano verbi italiani (Imposta-, Esegui-, Avvia-, Mostra-) per scelta.
        'PSUseApprovedVerbs',

        # Lo script e' un'interfaccia da console interattiva: Write-Host e' voluto.
        'PSAvoidUsingWriteHost',

        # I nomi italiani al plurale (es. Get-NumeroSchermi) non sono plurali inglesi.
        'PSUseSingularNouns'
    )

    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
