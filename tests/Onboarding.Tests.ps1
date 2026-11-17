#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $config = Get-ADFlowConfig -Path $configPath

    function Invoke-TestOnboarding {
        param([string] $CsvPath = $demoCsvPath, $Directory, [switch] $DryRun, [switch] $Preview)
        $logPath = Join-Path -Path $TestDrive -ChildPath 'runs'
        return @(Invoke-ADFlowOnboarding -CsvPath $CsvPath -Config $config -Directory $Directory -LogPath $logPath -DryRun:$DryRun -WhatIf:$Preview)
    }
    function Get-Result($Results, [string] $EmployeeId) {
        return @($Results | Where-Object { $_.EmployeeId -eq $EmployeeId })[0]
    }
    function Read-Journal($Result) {
        return @(Get-Content -Path (Join-Path -Path $Result.RunFolder -ChildPath 'audit.jsonl') -Encoding UTF8 | ConvertFrom-Json)
    }
}

Describe 'Invoke-ADFlowOnboarding with the demo file' {
    BeforeAll {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $results = Invoke-TestOnboarding -Directory $directory
    }

    It 'returns one result per row' {
        $results.Count | Should -Be 12
        @($results | Where-Object Status -eq 'Created').Count | Should -Be 8
        @($results | Where-Object Status -eq 'Rejected').Count | Should -Be 3
        @($results | Where-Object Status -eq 'Skipped').Count | Should -Be 1
    }

    It 'gives each new hire the expected user name' -TestCases @(
        @{ Id = 'E1001'; Sam = 'maria.garcial' }        # maria.garcia is taken
        @{ Id = 'E1002'; Sam = 'jose.pena' }
        @{ Id = 'E1003'; Sam = 'pedro.delafuente' }
        @{ Id = 'E1004'; Sam = 'inigo.martinezaragon' }
        @{ Id = 'E1005'; Sam = 'ana.garcia2' }          # ana.garcia and ana.garcial are taken
        @{ Id = 'E1006'; Sam = 'zoe.oconnor' }
        @{ Id = 'E1007'; Sam = 'maximiliano.fernande' } # 20 characters
        @{ Id = 'E1010'; Sam = 'jose.penam' }           # jose.pena was given earlier in the run
    ) {
        (Get-Result $results $Id).SamAccountName | Should -BeExactly $Sam
    }

    It 'creates the account in the department OU, enabled and with a password to change' {
        $user = $directory.FindUser('jose.pena')
        $user.ou | Should -Be 'OU=Finance,OU=Staff,DC=corp,DC=example,DC=com'
        $user.userPrincipalName | Should -Be 'jose.pena@corp.example.com'
        $user.mail | Should -Be 'jose.pena@corp.example.com'
        $user.displayName | Should -BeExactly 'José Ángel Peña Muñoz'
        $user.manager | Should -Be 'carlos.ruiz'
        $user.enabled | Should -BeTrue
        $user.changePasswordAtLogon | Should -BeTrue
    }

    It 'returns the temporary password only as a SecureString' {
        $result = Get-Result $results 'E1002'
        $result.Password | Should -BeOfType [securestring]
        (Get-Result $results 'E1008').Password | Should -BeNullOrEmpty
    }

    It 'adds the default groups and the groups of the role' {
        (Get-Result $results 'E1004').Groups | Should -Be @('GG-AllStaff', 'GG-IT-Admins', 'GG-VPN-Users')
        $directory.GetGroupMembers('GG-IT-Admins') | Should -Contain 'inigo.martinezaragon'
    }

    It 'warns about groups that are missing from the directory and skips them' {
        $result = Get-Result $results 'E1003'
        $result.Groups | Should -Not -Contain 'GG-CRM-Users'
        ($result.Warnings -join ' | ') | Should -Match 'GG-CRM-Users'
    }

    It 'warns about an unknown manager and creates the account without one' {
        $result = Get-Result $results 'E1007'
        $result.Status | Should -Be 'Created'
        ($result.Warnings -join ' | ') | Should -Match 'javier.moreno'
        $directory.FindUser('maximiliano.fernande').manager | Should -BeNullOrEmpty
    }

    It 'rejects invalid rows with the reason' {
        (Get-Result $results 'E1008').Message | Should -Match "Department 'Legal'"
        (Get-Result $results 'E1009').Message | Should -Match 'LastName is empty'
    }

    It 'skips employees that already have an account' {
        $result = Get-Result $results 'E0907'
        $result.Status | Should -Be 'Skipped'
        $result.SamAccountName | Should -Be 'laura.sanchez'
    }

    It 'logs every change with the way to undo it' {
        $journal = Read-Journal $results[0]
        $create = @($journal | Where-Object { $_.action -eq 'CreateUser' -and $_.target -eq 'jose.pena' })[0]
        $create.status | Should -Be 'Succeeded'
        $create.undo.Action | Should -Be 'RemoveUser'
        $create.details.Ou | Should -Be 'OU=Finance,OU=Staff,DC=corp,DC=example,DC=com'
        $group = @($journal | Where-Object { $_.action -eq 'AddGroupMember' -and $_.target -eq 'jose.pena' })[0]
        $group.undo.Action | Should -Be 'RemoveGroupMember'
        $group.undo.Group | Should -Be 'GG-AllStaff'
    }

    It 'never writes a password to the run folder' {
        foreach ($file in Get-ChildItem -Path $results[0].RunFolder -File) {
            [IO.File]::ReadAllText($file.FullName) | Should -Not -Match '"Password"'
        }
    }

    It 'does not create anything when run again with the same file' {
        $again = Invoke-TestOnboarding -Directory $directory
        @($again | Where-Object Status -eq 'Created').Count | Should -Be 0
        @($again | Where-Object Status -eq 'Skipped').Count | Should -Be 9
    }
}

Describe 'Invoke-ADFlowOnboarding -DryRun' {
    BeforeAll {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $before = $directory.Users.Count
        $results = Invoke-TestOnboarding -Directory $directory -DryRun
    }

    It 'plans the same names as a real run, without creating anything' {
        @($results | Where-Object Status -eq 'Planned').Count | Should -Be 8
        (Get-Result $results 'E1010').SamAccountName | Should -BeExactly 'jose.penam'
        $directory.Users.Count | Should -Be $before
        $directory.GetGroupMembers('GG-IT-Admins') | Should -Not -Contain 'inigo.martinezaragon'
    }

    It 'does not generate passwords' {
        @($results | Where-Object { $null -ne $_.Password }).Count | Should -Be 0
    }

    It 'logs the plan as Planned, with no undo' {
        $journal = Read-Journal $results[0]
        @($journal | Where-Object { $_.action -eq 'CreateUser' -and $_.status -eq 'Planned' }).Count | Should -Be 8
        @($journal | Where-Object { $null -ne $_.undo }).Count | Should -Be 0
        $summary = [IO.File]::ReadAllText((Join-Path -Path $results[0].RunFolder -ChildPath 'summary.json')) | ConvertFrom-Json
        $summary.mode | Should -Be 'DryRun'
    }
}

Describe 'Invoke-ADFlowOnboarding -WhatIf' {
    It 'changes nothing and logs the run as WhatIf' {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $before = $directory.Users.Count
        $results = Invoke-TestOnboarding -Directory $directory -Preview
        $directory.Users.Count | Should -Be $before
        @($results | Where-Object Status -eq 'WhatIf').Count | Should -Be 8
        Test-Path -Path (Join-Path -Path $results[0].RunFolder -ChildPath 'summary.json') | Should -BeTrue
    }
}

Describe 'Invoke-ADFlowOnboarding when the directory fails' {
    It 'marks the row as failed and goes on with the next one' {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $directory | Add-Member -MemberType ScriptMethod -Name NewUser -Force -Value {
            param([hashtable] $Spec)
            if ($Spec.SamAccountName -eq 'ana.soto') { throw 'Access is denied' }
            $this.Users[$Spec.SamAccountName] = [pscustomobject]@{ samAccountName = $Spec.SamAccountName; employeeId = $Spec.EmployeeId }
        }
        $csv = Write-TestHireFile -Rows 'E1,Ana,Soto,IT,Helpdesk Technician,,', 'E2,Luis,Soto,IT,Helpdesk Technician,,'
        $results = Invoke-TestOnboarding -CsvPath $csv -Directory $directory

        $results[0].Status | Should -Be 'Failed'
        $results[0].Message | Should -Be 'Access is denied'
        $results[1].Status | Should -Be 'Created'
        $failed = @(Read-Journal $results[0] | Where-Object { $_.status -eq 'Failed' })
        $failed[0].action | Should -Be 'CreateUser'
    }

    It 'fails a row whose OU is missing from the directory' {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        [void] $directory.Ous.Remove('OU=Marketing,OU=Staff,DC=corp,DC=example,DC=com')
        $csv = Write-TestHireFile -Rows 'E1,Ana,Soto,Marketing,Marketing Specialist,,'
        $result = (Invoke-TestOnboarding -CsvPath $csv -Directory $directory)[0]
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'OU=Marketing'
    }
}
