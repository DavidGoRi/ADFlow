#Requires -Version 5.1
<#
.SYNOPSIS
    Rollback: undoes the changes of an earlier run from its audit trail.

.DESCRIPTION
    Reads <run folder>\audit.jsonl, keeps the Succeeded entries that have an
    "undo" action and runs those actions from the last to the first:

      onboarding    the account is removed from its groups and deleted
      offboarding   the folder comes back, the account returns to its OU and
                    groups, gets its description back and is enabled

    The rollback is a run of its own, with its own audit trail. When it
    finishes, the original run gets a rollback.json file and cannot be undone
    a second time unless -Force is used.

    Only live runs can be undone: dry runs and -WhatIf runs changed nothing.
#>

function Undo-ADFlowRun {
    <#
    .SYNOPSIS
        Undoes a run. Returns one result per reverted action.
    .PARAMETER RunFolder
        The folder of the run to undo (output\runs\<RunId>).
    .OUTPUTS
        Objects with Sequence, OriginalAction, UndoAction, Target, Status
        (Reverted, Planned, WhatIf or Failed), Message, RunId and RunFolder.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $RunFolder,
        [Parameter(Mandatory)] $Directory,
        [Parameter(Mandatory)] [string] $LogPath,
        [switch] $DryRun,
        # Undo again a run that was already rolled back
        [switch] $Force
    )

    $RunFolder = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($RunFolder)
    $journal = Join-Path -Path $RunFolder -ChildPath 'audit.jsonl'
    $summaryPath = Join-Path -Path $RunFolder -ChildPath 'summary.json'
    $markerPath = Join-Path -Path $RunFolder -ChildPath 'rollback.json'
    if (-not (Test-Path -LiteralPath $journal)) { throw "No audit trail in $RunFolder" }
    if (-not (Test-Path -LiteralPath $summaryPath)) { throw "The run in $RunFolder did not finish (no summary.json): check audit.jsonl by hand" }

    $original = [IO.File]::ReadAllText($summaryPath) | ConvertFrom-Json
    if ($original.mode -ne 'Live') { throw "Run $($original.runId) was a $($original.mode) run and changed nothing" }
    if ($original.operation -eq 'Rollback') { throw "Run $($original.runId) is a rollback; it cannot be undone" }
    if ((Test-Path -LiteralPath $markerPath) -and -not $Force) {
        $marker = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json
        throw "Run $($original.runId) was already rolled back by $($marker.rollbackRunId); use -Force to undo it again"
    }

    $entries = @([IO.File]::ReadAllLines($journal) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    $undoable = @($entries | Where-Object { $_.status -eq 'Succeeded' -and $null -ne $_.undo } |
            Sort-Object -Property { [int] $_.sequence } -Descending)

    $mode = if ($DryRun) { 'DryRun' } elseif ($WhatIfPreference) { 'WhatIf' } else { 'Live' }
    $run = Initialize-ADFlowRun -LogPath $LogPath -Operation Rollback -Mode $mode -Provider $Directory.Name -Source $original.runId

    $results = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $reverted = 0
    foreach ($entry in $undoable) {
        $undo = $entry.undo
        $target = Get-ADFlowActionTarget -Action $undo
        $text = Get-ADFlowActionText -Action $undo
        $details = [ordered]@{ OriginalRunId = $original.runId; OriginalSequence = [int] $entry.sequence; OriginalAction = $entry.action }
        foreach ($property in $undo.PSObject.Properties) { if ($property.Name -ne 'Action') { $details[$property.Name] = $property.Value } }
        $audit = @{ Run = $run; EmployeeId = [string] $entry.employeeId; Action = [string] $undo.Action; Target = $target; Details = $details }

        $item = [pscustomobject][ordered]@{
            Sequence       = [int] $entry.sequence
            OriginalAction = $entry.action
            UndoAction     = $undo.Action
            Target         = $target
            Status         = $null
            Message        = $text
        }
        if ($mode -eq 'DryRun') {
            $item.Status = 'Planned'
            Write-ADFlowAuditEntry @audit -Status Planned -Message $text
        }
        elseif (-not $PSCmdlet.ShouldProcess($target, $text)) {
            $item.Status = 'WhatIf'
            Write-ADFlowAuditEntry @audit -Status WhatIf -Message $text
        }
        else {
            try {
                Invoke-ADFlowAction -Directory $Directory -Action $undo
                $item.Status = 'Reverted'
                $reverted++
                Write-ADFlowAuditEntry @audit -Status Succeeded -Message $text
            }
            catch {
                # One failure does not stop the rest: undo as much as possible
                $item.Status = 'Failed'
                $item.Message = "$text failed: $(Get-ADFlowErrorMessage $_)"
                Write-ADFlowAuditEntry @audit -Status Failed -Message $item.Message
            }
        }
        $results.Add($item)
    }

    if ($reverted) { $Directory.Save() }
    if ($mode -eq 'Live') {
        $marker = [ordered]@{
            rollbackRunId = $run.RunId
            at            = (Get-Date).ToString('o')
            reverted      = $reverted
            failed        = @($results | Where-Object Status -eq 'Failed').Count
        }
        [IO.File]::WriteAllText($markerPath, (ConvertTo-Json -InputObject $marker), (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    }
    [void] (Complete-ADFlowRun -Run $run -Results $results.ToArray())
    foreach ($item in $results) {
        $item | Add-Member -NotePropertyName RunId -NotePropertyValue $run.RunId
        $item | Add-Member -NotePropertyName RunFolder -NotePropertyValue $run.Folder
        $item
    }
}
