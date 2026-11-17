#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the live demo: a static site with a real ADFlow cycle on fictitious data.

.DESCRIPTION
    Runs, against the simulated directory and a temporary folder:
      1. the onboarding of demo/new-hires.csv (personal folders included);
      2. the offboarding of demo/leavers.csv;
      3. the rollback of that offboarding;
    and writes to -OutputPath:
      index.html          the guided tour, in English and Spanish
      onboarding.html     the HTML report of each run, as ADFlow writes it
      offboarding.html
      rollback.html
      welcome.html        one welcome email, as the manager would see it
      data/*.csv          the HR files used

    Local details (folders, user, computer) are replaced by fictitious ones,
    and the build fails if any is left. The Demo workflow publishes the site
    to GitHub Pages; tools/Update-Screenshots.ps1 takes the README pictures
    from it.

.EXAMPLE
    .\tools\Build-Demo.ps1 -OutputPath .\_site
#>
[CmdletBinding()]
param([string] $OutputPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) '_site'))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
foreach ($file in 'Naming', 'Password', 'Config', 'HRFile', 'MockDirectory', 'Audit', 'Actions', 'HomeFolder',
    'Welcome', 'Report', 'Onboarding', 'Offboarding', 'Rollback') {
    . (Join-Path -Path $root -ChildPath "src\$file.ps1")
}

$OutputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)
$work = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('adflow-demo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$homeRoot = Join-Path $work 'home'
$archiveRoot = Join-Path $work 'archive'
$logPath = Join-Path $work 'runs'
[void] [IO.Directory]::CreateDirectory($homeRoot)
# ana.garcial already has a folder, so the offboarding has something to archive
[void] [IO.Directory]::CreateDirectory((Join-Path $homeRoot 'ana.garcial'))

$hires = Join-Path $root 'demo\new-hires.csv'
$leavers = Join-Path $root 'demo\leavers.csv'
$config = Get-ADFlowConfig -Path (Join-Path $root 'config\adflow.json')
$config.homeFolders.root = $homeRoot
$config.offboarding.archiveRoot = $archiveRoot
$directory = Open-ADFlowMockDirectory -SeedPath (Join-Path $root 'demo\directory.json')

$onboarding = @(Invoke-ADFlowOnboarding -CsvPath $hires -Config $config -Directory $directory -LogPath $logPath)
$offboarding = @(Invoke-ADFlowOffboarding -CsvPath $leavers -Config $config -Directory $directory -LogPath $logPath)
$rollback = @(Undo-ADFlowRun -RunFolder $offboarding[0].RunFolder -Directory $directory -LogPath $logPath)

# Every local detail becomes a fictitious one
$fictitious = [ordered]@{
    $homeRoot                                    = '\\fs01.corp.example.com\home$'
    $archiveRoot                                 = '\\fs01.corp.example.com\archive$\home'
    $logPath                                     = 'D:\ADFlow\output\runs'
    $hires                                       = 'new-hires.csv'
    $leavers                                     = 'leavers.csv'
    ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) = 'CORP\it.admin'
    $env:COMPUTERNAME                            = 'ADM01'
}
function Hide-LocalDetail([string] $Text) {
    foreach ($key in $fictitious.Keys) {
        # Plain text and the JSON form (with doubled backslashes)
        $Text = $Text.Replace($key, $fictitious[$key]).Replace($key.Replace('\', '\\'), $fictitious[$key].Replace('\', '\\'))
    }
    return $Text
}

$utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
foreach ($run in $onboarding[0].RunFolder, $offboarding[0].RunFolder, $rollback[0].RunFolder) {
    foreach ($name in 'summary.json', 'audit.jsonl', 'rollback.json') {
        $path = Join-Path $run $name
        if (Test-Path -LiteralPath $path) { [IO.File]::WriteAllText($path, (Hide-LocalDetail ([IO.File]::ReadAllText($path))), $utf8) }
    }
}

if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Recurse -Force }
[void] [IO.Directory]::CreateDirectory((Join-Path $OutputPath 'data'))
$pages = [ordered]@{
    'onboarding.html'  = $onboarding[0].RunFolder
    'offboarding.html' = $offboarding[0].RunFolder
    'rollback.html'    = $rollback[0].RunFolder
}
foreach ($page in $pages.Keys) {
    $report = Export-ADFlowRunReport -RunFolder $pages[$page]
    Copy-Item -LiteralPath $report -Destination (Join-Path $OutputPath $page)
}
$welcome = ConvertFrom-ADFlowWelcomeMessage -Path (Join-Path $onboarding[0].RunFolder 'welcome\jose.pena.eml')
[IO.File]::WriteAllText((Join-Path $OutputPath 'welcome.html'), (Hide-LocalDetail $welcome.Body), $utf8)
Copy-Item -LiteralPath $hires, $leavers -Destination (Join-Path $OutputPath 'data')

# The console output of each step, as ADFlow.ps1 prints it
$statusClass = @{
    Created = 'ok'; Offboarded = 'ok'; Reverted = 'ok'; Planned = 'plan'; WhatIf = 'plan'
    Skipped = 'skip'; Rejected = 'warn'; Failed = 'bad'
}
function ConvertTo-DemoConsole([string] $Command, [object[]] $Results, [switch] $Undo) {
    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $lines.Add('<span class="prompt">PS&gt;</span> ' + (ConvertTo-ADFlowHtmlText -Text $Command))
    $lines.Add('')
    foreach ($item in $Results) {
        $class = $statusClass[[string] $item.Status]
        if ($Undo) {
            $text = '{0,-9} #{1,-4} {2,-18} {3}' -f $item.Status, $item.Sequence, $item.UndoAction, $item.Target
            $lines.Add(('<span class="{0}">{1}</span>' -f $class, (ConvertTo-ADFlowHtmlText -Text (Hide-LocalDetail $text))))
            continue
        }
        $name = if ($item.SamAccountName) { $item.SamAccountName } else { '-' }
        $text = '{0,-10} {1,-7} {2,-21} {3}' -f $item.Status, $item.EmployeeId, $name, $item.DisplayName
        $lines.Add(('<span class="{0}">{1}</span>' -f $class, (ConvertTo-ADFlowHtmlText -Text $text)))
        if ($item.Message) { $lines.Add('<span class="msg">           ' + (ConvertTo-ADFlowHtmlText -Text (Hide-LocalDetail $item.Message)) + '</span>') }
    }
    $counts = ($Results | Group-Object -Property Status | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }) -join ', '
    $lines.Add('')
    $lines.Add((ConvertTo-ADFlowHtmlText -Text "Run $($Results[0].RunId): $counts"))
    return $lines -join "`n"
}

function ConvertTo-DemoTable([string] $Path) {
    $csv = Read-ADFlowCsvFile -Path $Path
    $head = ($csv.Columns | ForEach-Object { '<th>{0}</th>' -f (ConvertTo-ADFlowHtmlText -Text $_) }) -join ''
    $body = foreach ($row in $csv.Rows) {
        '<tr>' + (($csv.Columns | ForEach-Object { '<td>{0}</td>' -f (ConvertTo-ADFlowHtmlText -Text ([string] $row.$_)) }) -join '') + '</tr>'
    }
    return "<table><thead><tr>$head</tr></thead><tbody>$($body -join "`n")</tbody></table>"
}

$count = { param($Results, $Status) @($Results | Where-Object Status -eq $Status).Count }
$values = @{
    Version          = ConvertTo-ADFlowHtmlText -Text $script:ADFlowVersion
    Generated        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
    HiresTable       = ConvertTo-DemoTable $hires
    LeaversTable     = ConvertTo-DemoTable $leavers
    OnboardConsole   = ConvertTo-DemoConsole '.\ADFlow.ps1 -Action Onboard -CsvPath .\new-hires.csv -HomeRoot \\fs01.corp.example.com\home$' $onboarding
    OffboardConsole  = ConvertTo-DemoConsole '.\ADFlow.ps1 -Action Offboard -CsvPath .\leavers.csv' $offboarding
    UndoConsole      = ConvertTo-DemoConsole ".\ADFlow.ps1 -Action Undo -RunId $($offboarding[0].RunId)" $rollback -Undo
    CreatedCount     = & $count $onboarding 'Created'
    OffboardedCount  = & $count $offboarding 'Offboarded'
    RevertedCount    = & $count $rollback 'Reverted'
    WelcomeTo        = ConvertTo-ADFlowHtmlText -Text $welcome.Headers['To']
    WelcomeSubject   = ConvertTo-ADFlowHtmlText -Text $welcome.Subject
}
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'demo\index.html'))
[IO.File]::WriteAllText((Join-Path $OutputPath 'index.html'), (Expand-ADFlowTemplate -Template $template -Values $values), $utf8)

# Nothing local may reach the site
$secrets = @($env:USERNAME, $env:COMPUTERNAME, [IO.Path]::GetTempPath().TrimEnd('\'), $root) | Where-Object { $_ }
foreach ($file in Get-ChildItem -LiteralPath $OutputPath -Recurse -File) {
    $text = [IO.File]::ReadAllText($file.FullName)
    foreach ($secret in $secrets) {
        if ($text.IndexOf($secret, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "A local detail is left in $($file.Name)" }
    }
}

# The personal folders were created with restricted permissions; the account
# running the demo has full control over them (see MockDirectory.ps1)
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Get-ChildItem -LiteralPath $OutputPath -Recurse -File | ForEach-Object {
    [pscustomobject]@{ File = $_.FullName.Substring($OutputPath.Length + 1); KB = [Math]::Round($_.Length / 1KB, 1) }
}
