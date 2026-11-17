#Requires -Version 5.1
<#
.SYNOPSIS
    ADFlow: automated joiner and leaver processing for Active Directory.

.DESCRIPTION
    Onboard  reads an HR file of new hires and creates their accounts: unique
             user name, OU by department, groups by job title and a temporary
             password that must be changed at the first logon.
    Offboard reads an HR file of leavers: disables the accounts, records and
             removes their groups, moves them to the leavers OU and archives
             their personal folders.
    Undo     reverts a previous Onboard or Offboard run from its audit trail.
    Report   writes the HTML report of a run again.

    Onboarding also creates each personal folder with its NTFS permissions
    and writes a welcome email draft (.eml) for each new hire.

    Every action goes to an audit trail under output\runs\<RunId>\.

    This version works with the simulated directory (-Provider Mock), so it
    runs on any Windows computer without a domain. The Active Directory
    provider comes in a later phase (see the README).

.EXAMPLE
    .\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv -DryRun
    Shows what would be created, without changing anything.

.EXAMPLE
    .\ADFlow.ps1 -Action Offboard -CsvPath .\demo\leavers.csv -WhatIf
    Standard PowerShell preview of each change.

.EXAMPLE
    .\ADFlow.ps1 -Action Undo -RunId 20261117-174300-56fe
    Reverts the changes of that run.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidateSet('Onboard', 'Offboard', 'Undo', 'Report')] [string] $Action,
    # HR file, for Onboard and Offboard
    [string] $CsvPath,
    # Run to revert (Undo) or to report on again (Report): a folder name under -LogPath
    [string] $RunId,
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'config\adflow.json'),
    [ValidateSet('Mock')] [string] $Provider = 'Mock',
    [string] $MockSeedPath = (Join-Path -Path $PSScriptRoot -ChildPath 'demo\directory.json'),
    [string] $MockStatePath = (Join-Path -Path $PSScriptRoot -ChildPath 'output\mock-directory.json'),
    [string] $LogPath = (Join-Path -Path $PSScriptRoot -ChildPath 'output\runs'),
    # Override homeFolders.root and offboarding.archiveRoot of the settings
    [string] $HomeRoot,
    [string] $ArchiveRoot,
    [switch] $DryRun,
    # Undo a run that was already rolled back
    [switch] $Force,
    # Starts the simulated directory again from the seed file
    [switch] $ResetMockDirectory,
    # Returns the result objects (temporary passwords as SecureString)
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
foreach ($file in 'Naming', 'Password', 'Config', 'HRFile', 'MockDirectory', 'Audit', 'Actions', 'HomeFolder',
    'Welcome', 'Report', 'Onboarding', 'Offboarding', 'Rollback') {
    . (Join-Path -Path $PSScriptRoot -ChildPath "src\$file.ps1")
}

if ($Action -in 'Onboard', 'Offboard' -and -not $CsvPath) { throw "-Action $Action needs -CsvPath" }
if ($Action -in 'Undo', 'Report' -and -not $RunId) { throw "-Action $Action needs -RunId (a folder name in the runs folder)" }
if ($Action -eq 'Report') {
    $report = Export-ADFlowRunReport -RunFolder (Join-Path -Path $LogPath -ChildPath $RunId)
    Write-Host "Report: $report"
    if ($PassThru) { $report }
    return
}

$config = Get-ADFlowConfig -Path $ConfigPath
# Absolute paths, so the audit trail can be undone from any folder
if ($HomeRoot) { $HomeRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($HomeRoot) }
if ($ArchiveRoot) { $ArchiveRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArchiveRoot) }
if ($HomeRoot) {
    if (-not $config.homeFolders) { $config | Add-Member -NotePropertyName homeFolders -NotePropertyValue ([pscustomobject]@{}) }
    $config.homeFolders | Add-Member -NotePropertyName root -NotePropertyValue $HomeRoot -Force
}
if ($ArchiveRoot -and $config.offboarding) {
    $config.offboarding | Add-Member -NotePropertyName archiveRoot -NotePropertyValue $ArchiveRoot -Force
}

if ($ResetMockDirectory -and (Test-Path -Path $MockStatePath)) {
    Remove-Item -Path $MockStatePath -WhatIf:$false
}
$directory = switch ($Provider) {
    'Mock' { Open-ADFlowMockDirectory -SeedPath $MockSeedPath -StatePath $MockStatePath }
}

$results = @(switch ($Action) {
        'Onboard' { Invoke-ADFlowOnboarding -CsvPath $CsvPath -Config $config -Directory $directory -LogPath $LogPath -DryRun:$DryRun }
        'Offboard' { Invoke-ADFlowOffboarding -CsvPath $CsvPath -Config $config -Directory $directory -LogPath $LogPath -DryRun:$DryRun }
        'Undo' {
            $runFolder = Join-Path -Path $LogPath -ChildPath $RunId
            Undo-ADFlowRun -RunFolder $runFolder -Directory $directory -LogPath $LogPath -DryRun:$DryRun -Force:$Force
        }
    })

$colors = @{
    Created = 'Green'; Offboarded = 'Green'; Reverted = 'Green'; Planned = 'Cyan'; WhatIf = 'Cyan'
    Skipped = 'DarkGray'; Rejected = 'Yellow'; Failed = 'Red'
}
Write-Host ''
foreach ($result in $results) {
    if ($Action -eq 'Undo') {
        $line = '{0,-9} #{1,-4} {2,-18} {3,-21} {4}' -f $result.Status, $result.Sequence, $result.UndoAction, $result.Target, $result.Message
        Write-Host $line -ForegroundColor $colors[$result.Status]
        continue
    }
    $name = if ($result.SamAccountName) { $result.SamAccountName } else { '-' }
    $line = '{0,-10} {1,-7} {2,-21} {3}' -f $result.Status, $result.EmployeeId, $name, $result.DisplayName
    Write-Host $line -ForegroundColor $colors[$result.Status]
    if ($result.Message) { Write-Host ('           {0}' -f $result.Message) -ForegroundColor DarkGray }
}
if ($results.Count) {
    $counts = ($results | Group-Object -Property Status | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }) -join ', '
    Write-Host ''
    Write-Host "Run $($results[0].RunId): $counts"
    Write-Host "Audit trail: $($results[0].RunFolder)"
    Write-Host "Report:      $(Join-Path -Path $results[0].RunFolder -ChildPath 'report.html')"
    $welcomeCount = @($results | Where-Object { $_.PSObject.Properties['WelcomeMessage'] -and $_.WelcomeMessage }).Count
    if ($welcomeCount) { Write-Host "Welcome messages (unsent drafts): $welcomeCount in $(Join-Path -Path $results[0].RunFolder -ChildPath 'welcome')" }
}
elseif ($Action -eq 'Undo') {
    Write-Host "Run $RunId has no changes to undo."
}
if (@($results | Where-Object Status -eq 'Created').Count) {
    Write-Host 'Temporary passwords are not shown or saved. Use -PassThru to get them as SecureString.' -ForegroundColor DarkGray
}
if ($PassThru) { $results }
