#Requires -Version 5.1
<#
.SYNOPSIS
    ADFlow: automated user onboarding for Active Directory.

.DESCRIPTION
    Reads an HR file of new hires and creates their accounts: unique user
    name, OU by department, groups by job title and a temporary password
    that must be changed at the first logon. Every action goes to an audit
    trail under output\runs\<RunId>\.

    This version works with the simulated directory (-Provider Mock), so it
    runs on any Windows computer without a domain. The Active Directory
    provider comes in a later phase (see the README).

.EXAMPLE
    .\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv -DryRun
    Shows what would be created, without changing anything.

.EXAMPLE
    .\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv -WhatIf
    Standard PowerShell preview of each change.

.EXAMPLE
    .\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv -ResetMockDirectory
    Creates the accounts in a fresh copy of the simulated directory.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidateSet('Onboard')] [string] $Action,
    [Parameter(Mandatory)] [string] $CsvPath,
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'config\adflow.json'),
    [ValidateSet('Mock')] [string] $Provider = 'Mock',
    [string] $MockSeedPath = (Join-Path -Path $PSScriptRoot -ChildPath 'demo\directory.json'),
    [string] $MockStatePath = (Join-Path -Path $PSScriptRoot -ChildPath 'output\mock-directory.json'),
    [string] $LogPath = (Join-Path -Path $PSScriptRoot -ChildPath 'output\runs'),
    [switch] $DryRun,
    # Starts the simulated directory again from the seed file
    [switch] $ResetMockDirectory,
    # Returns the result objects (with the temporary passwords as SecureString)
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
foreach ($file in 'Naming', 'Password', 'Config', 'HRFile', 'MockDirectory', 'Audit', 'Onboarding') {
    . (Join-Path -Path $PSScriptRoot -ChildPath "src\$file.ps1")
}

$config = Get-ADFlowConfig -Path $ConfigPath
if ($ResetMockDirectory -and (Test-Path -Path $MockStatePath)) {
    Remove-Item -Path $MockStatePath -WhatIf:$false
}
$directory = switch ($Provider) {
    'Mock' { Open-ADFlowMockDirectory -SeedPath $MockSeedPath -StatePath $MockStatePath }
}

$results = @(switch ($Action) {
        'Onboard' { Invoke-ADFlowOnboarding -CsvPath $CsvPath -Config $config -Directory $directory -LogPath $LogPath -DryRun:$DryRun }
    })

$colors = @{ Created = 'Green'; Planned = 'Cyan'; WhatIf = 'Cyan'; Skipped = 'DarkGray'; Rejected = 'Yellow'; Failed = 'Red' }
Write-Host ''
foreach ($result in $results) {
    $name = if ($result.SamAccountName) { $result.SamAccountName } else { '-' }
    $line = '{0,-9} {1,-7} {2,-21} {3}' -f $result.Status, $result.EmployeeId, $name, $result.DisplayName
    Write-Host $line -ForegroundColor $colors[$result.Status]
    if ($result.Message) { Write-Host ('          {0}' -f $result.Message) -ForegroundColor DarkGray }
}
if ($results.Count) {
    $counts = ($results | Group-Object -Property Status | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }) -join ', '
    Write-Host ''
    Write-Host "Run $($results[0].RunId): $counts"
    Write-Host "Audit trail: $($results[0].RunFolder)"
}
if (@($results | Where-Object Status -eq 'Created').Count) {
    Write-Host 'Temporary passwords are not shown or saved. Use -PassThru to get them as SecureString.' -ForegroundColor DarkGray
}
if ($PassThru) { $results }
