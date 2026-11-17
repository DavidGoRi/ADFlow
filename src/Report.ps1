#Requires -Version 5.1
<#
.SYNOPSIS
    HTML report of a run, built from its audit trail.

.DESCRIPTION
    report.html is written next to summary.json and audit.jsonl at the end of
    every run, and again on the original run when it is rolled back. It is a
    single self-contained file (no scripts, no external resources) that can be
    attached to a ticket, printed or opened offline. It follows the system
    light or dark theme.

    Every value is HTML-encoded: the report shows names typed by HR.
#>

$script:ADFlowStatusClass = @{
    Created = 's-ok'; Offboarded = 's-ok'; Reverted = 's-ok'; Succeeded = 's-ok'
    Planned = 's-plan'; WhatIf = 's-plan'
    Rejected = 's-warn'; Skipped = 's-skip'; Failed = 's-bad'
}

function ConvertTo-ADFlowHtml {
    # HTML-encodes a value; lists are joined with commas
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [Array]) { $Value = ($Value | ForEach-Object { [string] $_ }) -join ', ' }
    return ConvertTo-ADFlowHtmlText -Text ([string] $Value)
}

function Get-ADFlowStatusChip {
    param([string] $Status)
    $class = $script:ADFlowStatusClass[$Status]
    if (-not $class) { $class = 's-skip' }
    return '<span class="chip {0}">{1}</span>' -f $class, (ConvertTo-ADFlowHtml $Status)
}

function Get-ADFlowShortOu {
    # "OU=IT,OU=Staff,DC=corp,..." -> "IT / Staff", with the full DN as a tooltip
    param([string] $DistinguishedName)
    if (-not $DistinguishedName) { return '' }
    $names = @([regex]::Matches($DistinguishedName, 'OU=([^,]+)') | ForEach-Object { $_.Groups[1].Value })
    return '<span title="{0}">{1}</span>' -f (ConvertTo-ADFlowHtml $DistinguishedName), (ConvertTo-ADFlowHtml ($names -join ' / '))
}

function Format-ADFlowActionDetail {
    # The details of an audit entry as one short line of HTML
    param($Entry)
    $parts = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($Entry.details) {
        foreach ($property in $Entry.details.PSObject.Properties) {
            if ($property.Name -eq 'SamAccountName' -or $null -eq $property.Value -or '' -eq $property.Value) { continue }
            $value = $property.Value
            if ($property.Name -eq 'Acl') {
                $value = @($value | ForEach-Object { '{0}: {1}' -f $_.Identity, $_.Rights })
            }
            $parts.Add(('{0}: {1}' -f (ConvertTo-ADFlowHtml $property.Name), (ConvertTo-ADFlowHtml $value)))
        }
    }
    if ($Entry.message) { $parts.Add((ConvertTo-ADFlowHtml $Entry.message)) }
    return $parts -join ' &middot; '
}

function Export-ADFlowRunReport {
    <#
    .SYNOPSIS
        Writes <run folder>\report.html and returns its path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $RunFolder)

    $RunFolder = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($RunFolder)
    $summaryPath = Join-Path -Path $RunFolder -ChildPath 'summary.json'
    if (-not (Test-Path -LiteralPath $summaryPath)) { throw "No summary.json in $RunFolder" }
    $summary = [IO.File]::ReadAllText($summaryPath) | ConvertFrom-Json
    $journal = Join-Path -Path $RunFolder -ChildPath 'audit.jsonl'
    $entries = @()
    if (Test-Path -LiteralPath $journal) {
        $entries = @([IO.File]::ReadAllLines($journal) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    $results = @($summary.results | Where-Object { $null -ne $_ })

    # Banners: nothing changed, or changes undone later
    $banners = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($summary.mode -eq 'DryRun') { $banners.Add('<div class="banner">Dry run: this is the plan. Nothing was changed.</div>') }
    if ($summary.mode -eq 'WhatIf') { $banners.Add('<div class="banner">-WhatIf run: nothing was changed.</div>') }
    $markerPath = Join-Path -Path $RunFolder -ChildPath 'rollback.json'
    if (Test-Path -LiteralPath $markerPath) {
        $marker = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json
        $banners.Add(('<div class="banner rolled">This run was rolled back by run <code>{0}</code> ({1} change(s) reverted, {2} failed).</div>' -f
                (ConvertTo-ADFlowHtml $marker.rollbackRunId), [int] $marker.reverted, [int] $marker.failed))
    }

    # One tile per status
    $tiles = foreach ($group in ($results | Group-Object -Property Status | Sort-Object -Property Name)) {
        '<div class="tile"><b>{0}</b>{1}</div>' -f $group.Count, (Get-ADFlowStatusChip $group.Name)
    }
    if (-not $tiles) { $tiles = '<div class="tile"><b>0</b><span>rows</span></div>' }

    # The results table depends on the operation
    switch ($summary.operation) {
        'Onboarding' {
            $headers = 'Row', 'Employee', 'Name', 'User name', 'OU', 'Groups', 'Personal folder', 'Status', 'Notes'
            $rows = foreach ($item in $results) {
                '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><code>{3}</code></td><td>{4}</td><td>{5}</td><td>{6}</td><td>{7}</td><td class="notes">{8}</td></tr>' -f
                (ConvertTo-ADFlowHtml $item.Row), (ConvertTo-ADFlowHtml $item.EmployeeId), (ConvertTo-ADFlowHtml $item.DisplayName),
                (ConvertTo-ADFlowHtml $item.SamAccountName), (Get-ADFlowShortOu $item.Ou), (ConvertTo-ADFlowHtml @($item.Groups)),
                (ConvertTo-ADFlowHtml $item.HomeFolder), (Get-ADFlowStatusChip $item.Status), (ConvertTo-ADFlowHtml $item.Message)
            }
        }
        'Offboarding' {
            $headers = 'Row', 'Employee', 'Name', 'User name', 'Previous OU', 'Groups removed', 'Archived to', 'Status', 'Notes'
            $rows = foreach ($item in $results) {
                '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><code>{3}</code></td><td>{4}</td><td>{5}</td><td>{6}</td><td>{7}</td><td class="notes">{8}</td></tr>' -f
                (ConvertTo-ADFlowHtml $item.Row), (ConvertTo-ADFlowHtml $item.EmployeeId), (ConvertTo-ADFlowHtml $item.DisplayName),
                (ConvertTo-ADFlowHtml $item.SamAccountName), (Get-ADFlowShortOu $item.PreviousOu), (ConvertTo-ADFlowHtml @($item.Groups)),
                (ConvertTo-ADFlowHtml $item.ArchivedTo), (Get-ADFlowStatusChip $item.Status), (ConvertTo-ADFlowHtml $item.Message)
            }
        }
        default {
            $headers = 'Original #', 'Original action', 'Undo action', 'Target', 'Status', 'Notes'
            $rows = foreach ($item in $results) {
                '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><code>{3}</code></td><td>{4}</td><td class="notes">{5}</td></tr>' -f
                (ConvertTo-ADFlowHtml $item.Sequence), (ConvertTo-ADFlowHtml $item.OriginalAction), (ConvertTo-ADFlowHtml $item.UndoAction),
                (ConvertTo-ADFlowHtml $item.Target), (Get-ADFlowStatusChip $item.Status), (ConvertTo-ADFlowHtml $item.Message)
            }
        }
    }
    $columnCount = @($headers).Count
    if (-not $rows) { $rows = '<tr><td colspan="{0}">No rows.</td></tr>' -f $columnCount }

    $actionRows = foreach ($entry in $entries) {
        $time = ''
        $stamp = [datetime]::MinValue
        if ([datetime]::TryParse([string] $entry.timestamp, [ref] $stamp)) { $time = $stamp.ToString('HH:mm:ss') }
        $undoMark = if ($null -ne $entry.undo) { ' <span class="undo" title="Can be undone">&#8634;</span>' } else { '' }
        '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}{4}</td><td><code>{5}</code></td><td>{6}</td><td class="notes">{7}</td></tr>' -f
        [int] $entry.sequence, $time, (ConvertTo-ADFlowHtml $entry.employeeId), (ConvertTo-ADFlowHtml $entry.action), $undoMark,
        (ConvertTo-ADFlowHtml $entry.target), (Get-ADFlowStatusChip $entry.status), (Format-ADFlowActionDetail $entry)
    }
    if (-not $actionRows) { $actionRows = '<tr><td colspan="7">No actions.</td></tr>' }

    $format = { param($text) $parsed = [datetime]::MinValue; if ([datetime]::TryParse([string] $text, [ref] $parsed)) { $parsed.ToString('yyyy-MM-dd HH:mm:ss') } else { [string] $text } }
    $values = @{
        Title         = ConvertTo-ADFlowHtml ('ADFlow {0} run' -f $summary.operation)
        Operation     = ConvertTo-ADFlowHtml $summary.operation
        RunId         = ConvertTo-ADFlowHtml $summary.runId
        Mode          = ConvertTo-ADFlowHtml $summary.mode
        Provider      = ConvertTo-ADFlowHtml $summary.provider
        Source        = ConvertTo-ADFlowHtml $summary.source
        Operator      = ConvertTo-ADFlowHtml $summary.operator
        Computer      = ConvertTo-ADFlowHtml $summary.computer
        Started       = ConvertTo-ADFlowHtml (& $format $summary.startedAt)
        Finished      = ConvertTo-ADFlowHtml (& $format $summary.finishedAt)
        Banners       = $banners -join "`n  "
        Tiles         = @($tiles) -join ''
        ResultHeaders = (@($headers) | ForEach-Object { "<th>$_</th>" }) -join ''
        ResultRows    = @($rows) -join "`n"
        ActionCount   = $entries.Count
        ActionRows    = @($actionRows) -join "`n"
        Generated     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $template = [IO.File]::ReadAllText((Join-Path -Path $PSScriptRoot -ChildPath 'report-template.html'))
    $html = Expand-ADFlowTemplate -Template $template -Values $values
    $path = Join-Path -Path $RunFolder -ChildPath 'report.html'
    [IO.File]::WriteAllText($path, $html, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    return $path
}
