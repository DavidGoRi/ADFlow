#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
}

Describe 'Audit trail' {
    BeforeEach {
        $run = Initialize-ADFlowRun -LogPath (Join-Path -Path $TestDrive -ChildPath 'runs') -Operation Onboarding -Mode Live -Provider Mock -Source 'hires.csv'
    }

    It 'creates one folder per run with a sortable id' {
        $run.RunId | Should -Match '^\d{8}-\d{6}-[0-9a-f]{4}$'
        Test-Path -Path $run.Folder -PathType Container | Should -BeTrue
    }

    It 'appends each action to audit.jsonl as it happens' {
        Write-ADFlowAuditEntry -Run $run -Action CreateUser -Target 'eva.mora' -Status Succeeded -EmployeeId 'E1' `
            -Undo ([ordered]@{ Action = 'RemoveUser'; SamAccountName = 'eva.mora' })
        Write-ADFlowAuditEntry -Run $run -Action AddGroupMember -Target 'eva.mora' -Status Failed -Message 'no group'

        $lines = @(Get-Content -Path $run.JournalPath -Encoding UTF8)
        $lines.Count | Should -Be 2
        $first = $lines[0] | ConvertFrom-Json
        $first.sequence | Should -Be 1
        $first.employeeId | Should -Be 'E1'
        $first.undo.Action | Should -Be 'RemoveUser'
        ($lines[1] | ConvertFrom-Json).message | Should -Be 'no group'
    }

    It 'refuses to log a password' {
        { Write-ADFlowAuditEntry -Run $run -Action CreateUser -Target 'x' -Status Succeeded -Details @{ Password = 'secret' } } |
            Should -Throw '*passwords*'
        { Write-ADFlowAuditEntry -Run $run -Action CreateUser -Target 'x' -Status Succeeded -Details @{ Initial = (Get-ADFlowRandomPassword) } } |
            Should -Throw '*passwords*'
    }

    It 'writes audit.csv and summary.json without passwords' {
        Write-ADFlowAuditEntry -Run $run -Action CreateUser -Target 'eva.mora' -Status Succeeded
        $results = @(
            [pscustomobject]@{ EmployeeId = 'E1'; Status = 'Created'; Password = (Get-ADFlowRandomPassword) }
            [pscustomobject]@{ EmployeeId = 'E2'; Status = 'Rejected'; Password = $null }
            [pscustomobject]@{ EmployeeId = 'E3'; Status = 'Created'; Password = (Get-ADFlowRandomPassword) }
        )
        $summary = Complete-ADFlowRun -Run $run -Results $results

        $summary.counts.Created | Should -Be 2
        $summary.counts.Rejected | Should -Be 1
        $csv = @(Import-Csv -Path (Join-Path -Path $run.Folder -ChildPath 'audit.csv'))
        $csv[0].action | Should -Be 'CreateUser'
        $json = [IO.File]::ReadAllText((Join-Path -Path $run.Folder -ChildPath 'summary.json'))
        $json | Should -Not -Match 'Password'
        ($json | ConvertFrom-Json).results.Count | Should -Be 3
    }

    It 'still writes an empty journal when nothing happened' {
        [void] (Complete-ADFlowRun -Run $run -Results @())
        Test-Path -Path $run.JournalPath | Should -BeTrue
    }
}
