#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $leaversCsvPath = Join-Path -Path $repoRoot -ChildPath 'demo\leavers.csv'

    function Get-TestConfig {
        $local = Get-ADFlowConfig -Path $configPath
        $local.homeFolders.root = Join-Path -Path $TestDrive -ChildPath 'home'
        $local.offboarding.archiveRoot = Join-Path -Path $TestDrive -ChildPath 'archive'
        return $local
    }
    function Get-LogPath { return Join-Path -Path $TestDrive -ChildPath 'runs' }

    # A snapshot of what rollback must restore
    function Get-UserState($Directory, [string] $SamAccountName) {
        $user = $Directory.FindUser($SamAccountName)
        return '{0}|{1}|{2}|{3}' -f $user.enabled, $user.ou, $user.description, ($Directory.GetUserGroups($SamAccountName) -join ',')
    }
}

Describe 'Undo-ADFlowRun after an offboarding' {
    BeforeAll {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $homeFolder = Join-Path -Path $TestDrive -ChildPath 'home\ana.garcial'
        [void] [IO.Directory]::CreateDirectory($homeFolder)
        [IO.File]::WriteAllText((Join-Path -Path $homeFolder -ChildPath 'notes.txt'), 'fictitious')
        $before = @{
            ana    = Get-UserState $directory 'ana.garcial'
            carlos = Get-UserState $directory 'carlos.ruiz'
        }
        $offboarding = @(Invoke-ADFlowOffboarding -CsvPath $leaversCsvPath -Config (Get-TestConfig) -Directory $directory -LogPath (Get-LogPath))
        $runFolder = $offboarding[0].RunFolder
        $undo = @(Undo-ADFlowRun -RunFolder $runFolder -Directory $directory -LogPath (Get-LogPath))
    }

    It 'restores the accounts exactly as they were' {
        Get-UserState $directory 'ana.garcial' | Should -BeExactly $before.ana
        Get-UserState $directory 'carlos.ruiz' | Should -BeExactly $before.carlos
    }

    It 'brings the personal folder back from the archive' {
        Test-Path -Path (Join-Path -Path $homeFolder -ChildPath 'notes.txt') | Should -BeTrue
        @(Get-ChildItem -Path (Join-Path -Path $TestDrive -ChildPath 'archive')).Count | Should -Be 0
    }

    It 'reverts the actions from the last to the first' {
        $sequences = @($undo | ForEach-Object { $_.Sequence })
        $sequences | Should -Be @($sequences | Sort-Object -Descending)
        @($undo | Where-Object Status -ne 'Reverted').Count | Should -Be 0
    }

    It 'is a run of its own, linked to the original one' {
        $summary = [IO.File]::ReadAllText((Join-Path -Path $undo[0].RunFolder -ChildPath 'summary.json')) | ConvertFrom-Json
        $summary.operation | Should -Be 'Rollback'
        $summary.source | Should -Be $offboarding[0].RunId
        $marker = [IO.File]::ReadAllText((Join-Path -Path $runFolder -ChildPath 'rollback.json')) | ConvertFrom-Json
        $marker.rollbackRunId | Should -Be $undo[0].RunId
        $marker.reverted | Should -Be $undo.Count
    }

    It 'refuses to undo the same run twice without -Force' {
        { Undo-ADFlowRun -RunFolder $runFolder -Directory $directory -LogPath (Get-LogPath) } | Should -Throw '*already rolled back*'
    }

    It 'refuses to undo a rollback' {
        { Undo-ADFlowRun -RunFolder $undo[0].RunFolder -Directory $directory -LogPath (Get-LogPath) } | Should -Throw '*is a rollback*'
    }
}

Describe 'Undo-ADFlowRun after an onboarding' {
    It 'deletes the accounts that were created and leaves the rest' {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $before = $directory.Users.Count
        $created = @(Invoke-ADFlowOnboarding -CsvPath $demoCsvPath -Config (Get-TestConfig) -Directory $directory -LogPath (Get-LogPath))
        $directory.Users.Count | Should -Be ($before + 8)

        $undo = @(Undo-ADFlowRun -RunFolder $created[0].RunFolder -Directory $directory -LogPath (Get-LogPath))
        $directory.Users.Count | Should -Be $before
        $directory.FindUser('maria.garcial') | Should -BeNullOrEmpty
        $directory.FindUser('maria.garcia') | Should -Not -BeNullOrEmpty
        $directory.GetGroupMembers('GG-AllStaff') | Should -Not -Contain 'jose.pena'
        @($undo | Where-Object UndoAction -eq 'RemoveUser').Count | Should -Be 8
        # Group removals come before the account is deleted
        $undo[-1].UndoAction | Should -Be 'RemoveUser'
    }
}

Describe 'Undo-ADFlowRun modes and errors' {
    BeforeEach {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $csv = Write-TestHireFile -Header 'SamAccountName' -Rows 'carlos.ruiz'
        $offboarding = @(Invoke-ADFlowOffboarding -CsvPath $csv -Config (Get-TestConfig) -Directory $directory -LogPath (Get-LogPath))
        $runFolder = $offboarding[0].RunFolder
    }

    It 'plans with -DryRun and leaves the run open for a real rollback' {
        $plan = @(Undo-ADFlowRun -RunFolder $runFolder -Directory $directory -LogPath (Get-LogPath) -DryRun)
        @($plan | Where-Object Status -eq 'Planned').Count | Should -Be $plan.Count
        $directory.FindUser('carlos.ruiz').enabled | Should -BeFalse
        Test-Path -Path (Join-Path -Path $runFolder -ChildPath 'rollback.json') | Should -BeFalse
    }

    It 'previews with -WhatIf' {
        $plan = @(Undo-ADFlowRun -RunFolder $runFolder -Directory $directory -LogPath (Get-LogPath) -WhatIf)
        @($plan | Where-Object Status -eq 'WhatIf').Count | Should -Be $plan.Count
        $directory.FindUser('carlos.ruiz').enabled | Should -BeFalse
    }

    It 'goes on after a failure and reports it' {
        $directory | Add-Member -MemberType ScriptMethod -Name AddGroupMember -Force -Value { throw 'Access is denied' }
        $undo = @(Undo-ADFlowRun -RunFolder $runFolder -Directory $directory -LogPath (Get-LogPath))
        @($undo | Where-Object Status -eq 'Failed').Count | Should -Be 3
        @($undo | Where-Object Message -match 'Access is denied').Count | Should -Be 3
        $directory.FindUser('carlos.ruiz').enabled | Should -BeTrue
        ([IO.File]::ReadAllText((Join-Path -Path $runFolder -ChildPath 'rollback.json')) | ConvertFrom-Json).failed | Should -Be 3
    }

    It 'undoes a run again with -Force' {
        [void] (Undo-ADFlowRun -RunFolder $runFolder -Directory $directory -LogPath (Get-LogPath))
        { Undo-ADFlowRun -RunFolder $runFolder -Directory $directory -LogPath (Get-LogPath) -Force } | Should -Not -Throw
    }

    It 'refuses dry runs, unfinished runs and missing folders' {
        $dry = @(Invoke-ADFlowOffboarding -CsvPath $csv -Config (Get-TestConfig) -Directory $directory -LogPath (Get-LogPath) -DryRun)
        { Undo-ADFlowRun -RunFolder $dry[0].RunFolder -Directory $directory -LogPath (Get-LogPath) } | Should -Throw '*DryRun run*'
        Remove-Item -Path (Join-Path -Path $runFolder -ChildPath 'summary.json')
        { Undo-ADFlowRun -RunFolder $runFolder -Directory $directory -LogPath (Get-LogPath) } | Should -Throw '*did not finish*'
        { Undo-ADFlowRun -RunFolder (Join-Path -Path $TestDrive -ChildPath 'nope') -Directory $directory -LogPath (Get-LogPath) } | Should -Throw '*No audit trail*'
    }
}
