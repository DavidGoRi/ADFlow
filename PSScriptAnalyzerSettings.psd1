@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # ADFlow.ps1 is an interactive entry point: coloured console output is intended
        'PSAvoidUsingWriteHost'
    )
}
