#Requires -Version 5.1
<#
.SYNOPSIS
    Audit trail of every run: what was done, to whom, and how to undo it.

.DESCRIPTION
    Each run gets its own folder, <LogPath>\<RunId>\, with:

      audit.jsonl    one JSON object per action, written as it happens, so a
                     run that stops halfway still leaves its trail
      audit.csv      the same actions as a table, for Excel
      summary.json   run details and one line per HR row with its result

    Every change carries an "undo" object with the reverse action (for example
    RemoveGroupMember for AddGroupMember). The rollback command of phase 2
    reads it back in reverse order.

    Passwords are never written: entries only say that one was set.
    The files are written with .NET so that -WhatIf does not skip the log.
#>

$script:ADFlowUtf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

function Initialize-ADFlowRun {
    <#
    .SYNOPSIS
        Creates the folder of a new run and returns the run object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [ValidateSet('Onboarding', 'Offboarding', 'Rollback')] [string] $Operation,
        [Parameter(Mandatory)] [ValidateSet('Live', 'DryRun', 'WhatIf')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Provider,
        [string] $Source
    )

    $started = Get-Date
    $suffix = -join ((1..4) | ForEach-Object { '{0:x}' -f (Get-ADFlowRandomIndex -Count 16) })
    $runId = '{0}-{1}' -f $started.ToString('yyyyMMdd-HHmmss'), $suffix
    $folder = Join-Path -Path $PSCmdlet.GetUnresolvedProviderPathFromPSPath($LogPath) -ChildPath $runId
    [void] [IO.Directory]::CreateDirectory($folder)

    return [pscustomobject]@{
        RunId       = $runId
        Operation   = $Operation
        Mode        = $Mode
        Provider    = $Provider
        Source      = $Source
        Operator    = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
        Computer    = $env:COMPUTERNAME
        StartedAt   = $started
        Folder      = $folder
        JournalPath = Join-Path -Path $folder -ChildPath 'audit.jsonl'
        Entries     = New-Object -TypeName 'System.Collections.Generic.List[object]'
    }
}

function Write-ADFlowAuditEntry {
    <#
    .SYNOPSIS
        Adds an action to the run and appends it to audit.jsonl.
    .PARAMETER Status
        Succeeded, Failed, Planned (dry run), WhatIf, Skipped or Rejected.
    .PARAMETER Undo
        The reverse action, for changes that can be undone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Target,
        [Parameter(Mandatory)] [ValidateSet('Succeeded', 'Failed', 'Planned', 'WhatIf', 'Skipped', 'Rejected')] [string] $Status,
        [string] $Message = '',
        [string] $EmployeeId = '',
        [Collections.IDictionary] $Details = @{},
        [Collections.IDictionary] $Undo
    )

    foreach ($key in @($Details.Keys)) {
        if ($key -eq 'Password' -or $Details[$key] -is [securestring]) {
            throw "Audit details must not contain passwords ($key)"
        }
    }
    $entry = [pscustomobject][ordered]@{
        timestamp  = (Get-Date).ToString('o')
        runId      = $Run.RunId
        sequence   = $Run.Entries.Count + 1
        action     = $Action
        target     = $Target
        employeeId = $EmployeeId
        status     = $Status
        message    = $Message
        details    = $Details
        undo       = $Undo
    }
    $Run.Entries.Add($entry)
    $line = ConvertTo-Json -InputObject $entry -Depth 6 -Compress
    [IO.File]::AppendAllText($Run.JournalPath, $line + "`n", $script:ADFlowUtf8)
}

function Complete-ADFlowRun {
    <#
    .SYNOPSIS
        Writes audit.csv and summary.json and returns the summary.
    .PARAMETER Results
        One object per HR row. Any Password property is left out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results
    )

    $csvPath = Join-Path -Path $Run.Folder -ChildPath 'audit.csv'
    $csv = @($Run.Entries | Select-Object -Property timestamp, sequence, employeeId, action, target, status, message |
            ConvertTo-Csv -NoTypeInformation)
    [IO.File]::WriteAllLines($csvPath, [string[]] $csv, $script:ADFlowUtf8)
    if (-not (Test-Path -Path $Run.JournalPath)) {
        # A run without actions still has an (empty) journal
        [IO.File]::WriteAllText($Run.JournalPath, '', $script:ADFlowUtf8)
    }

    $counts = [ordered]@{}
    foreach ($group in ($Results | Group-Object -Property Status | Sort-Object -Property Name)) {
        $counts[$group.Name] = $group.Count
    }
    $summary = [pscustomobject][ordered]@{
        runId      = $Run.RunId
        operation  = $Run.Operation
        mode       = $Run.Mode
        provider   = $Run.Provider
        source     = $Run.Source
        operator   = $Run.Operator
        computer   = $Run.Computer
        startedAt  = $Run.StartedAt.ToString('o')
        finishedAt = (Get-Date).ToString('o')
        actions    = $Run.Entries.Count
        counts     = $counts
        results    = @($Results | Select-Object -Property * -ExcludeProperty Password)
        folder     = $Run.Folder
    }
    $json = ConvertTo-Json -InputObject $summary -Depth 6
    [IO.File]::WriteAllText((Join-Path -Path $Run.Folder -ChildPath 'summary.json'), $json, $script:ADFlowUtf8)
    return $summary
}
