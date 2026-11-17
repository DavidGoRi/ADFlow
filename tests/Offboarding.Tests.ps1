#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $leaversCsvPath = Join-Path -Path $repoRoot -ChildPath 'demo\leavers.csv'
    $date = [datetime] '2026-11-30'

    # Settings with the personal folders in TestDrive
    function Get-TestConfig {
        $local = Get-ADFlowConfig -Path $configPath
        $local.homeFolders.root = Join-Path -Path $TestDrive -ChildPath 'home'
        $local.offboarding.archiveRoot = Join-Path -Path $TestDrive -ChildPath 'archive'
        return $local
    }
    function Invoke-TestOffboarding {
        param([string] $CsvPath = $leaversCsvPath, $Directory, $Config = (Get-TestConfig), [switch] $DryRun, [switch] $Preview)
        $logPath = Join-Path -Path $TestDrive -ChildPath 'runs'
        return @(Invoke-ADFlowOffboarding -CsvPath $CsvPath -Config $Config -Directory $Directory -LogPath $logPath -Date $date -DryRun:$DryRun -WhatIf:$Preview)
    }
    function Get-Result($Results, [string] $SamAccountName) {
        return @($Results | Where-Object { $_.SamAccountName -eq $SamAccountName })[0]
    }
    function Read-Journal($Result) {
        return @(Get-Content -Path (Join-Path -Path $Result.RunFolder -ChildPath 'audit.jsonl') -Encoding UTF8 | ConvertFrom-Json)
    }
    function Add-TestHomeFolder([string] $SamAccountName) {
        $folder = Join-Path -Path $TestDrive -ChildPath "home\$SamAccountName\Documents"
        [void] [IO.Directory]::CreateDirectory($folder)
        [IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath 'notes.txt'), 'fictitious')
    }
}

Describe 'Import-ADFlowLeaverFile' {
    It 'reads the demo file and validates every row' {
        $rows = @(Import-ADFlowLeaverFile -Path $leaversCsvPath)
        $rows.Count | Should -Be 8
        $rows[0].EmployeeId | Should -Be 'E0903'
        $rows[0].LeaveDate | Should -Be ([datetime] '2026-11-30')
        $rows[0].Reason | Should -Be 'Resignation'
        $rows[1].SamAccountName | Should -Be 'carlos.ruiz'
        $rows[7].Errors | Should -Be 'E0903 is repeated (first on row 2)'
    }

    It 'accepts a file with only SamAccountName' {
        $path = Write-TestHireFile -Header 'SamAccountName' -Rows 'ana.soto'
        (Import-ADFlowLeaverFile -Path $path).SamAccountName | Should -Be 'ana.soto'
    }

    It 'needs an EmployeeId or SamAccountName column, and a value in each row' {
        $path = Write-TestHireFile -Header 'Name,LeaveDate' -Rows 'Ana,2026-11-30'
        { Import-ADFlowLeaverFile -Path $path } | Should -Throw '*EmployeeId or a SamAccountName*'
        $path = Write-TestHireFile -Header 'EmployeeId,SamAccountName,LeaveDate' -Rows ',,2026-11-30'
        (Import-ADFlowLeaverFile -Path $path).Errors | Should -Match 'both empty'
    }

    It 'reports an invalid leave date' {
        $path = Write-TestHireFile -Header 'EmployeeId,LeaveDate' -Rows 'E1,30/11/2026'
        (Import-ADFlowLeaverFile -Path $path).Errors | Should -Match 'yyyy-MM-dd'
    }
}

Describe 'Invoke-ADFlowOffboarding with the demo file' {
    BeforeAll {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        Add-TestHomeFolder 'ana.garcial'
        $results = Invoke-TestOffboarding -Directory $directory
    }

    It 'returns one result per row' {
        $results.Count | Should -Be 8
        @($results | Where-Object Status -eq 'Offboarded').Count | Should -Be 2
        @($results | Where-Object Status -eq 'Skipped').Count | Should -Be 1
        @($results | Where-Object Status -eq 'Rejected').Count | Should -Be 4
        @($results | Where-Object Status -eq 'Failed').Count | Should -Be 1
    }

    It 'disables the account, moves it to the leavers OU and writes the reason' {
        $user = $directory.FindUser('ana.garcial')
        $user.enabled | Should -BeFalse
        $user.ou | Should -Be 'OU=Leavers,DC=corp,DC=example,DC=com'
        $user.description | Should -BeLike 'Left on 2026-11-30 (Resignation) - ADFlow *'
    }

    It 'removes the groups except the ones to keep' {
        $directory.GetUserGroups('carlos.ruiz') | Should -Be @('Domain Users')
        (Get-Result $results 'carlos.ruiz').Groups | Should -Be @('GG-AllStaff', 'GG-ERP-Users', 'GG-Finance-Users')
    }

    It 'records the group membership before changing anything' {
        $journal = Read-Journal $results[0]
        $record = @($journal | Where-Object { $_.action -eq 'RecordGroups' -and $_.target -eq 'carlos.ruiz' })[0]
        $record.details.Groups | Should -Be @('Domain Users', 'GG-AllStaff', 'GG-ERP-Users', 'GG-Finance-Users')
        $record.details.Ou | Should -Be 'OU=Finance,OU=Staff,DC=corp,DC=example,DC=com'
        $first = @($journal | Where-Object { $_.target -eq 'carlos.ruiz' })[0]
        $first.action | Should -Be 'RecordGroups'
    }

    It 'archives the personal folder with the date in its name' {
        $archive = Join-Path -Path $TestDrive -ChildPath 'archive\ana.garcial_20261130'
        (Get-Result $results 'ana.garcial').ArchivedTo | Should -Be $archive
        Test-Path -Path (Join-Path -Path $archive -ChildPath 'Documents\notes.txt') | Should -BeTrue
        Test-Path -Path (Join-Path -Path $TestDrive -ChildPath 'home\ana.garcial') | Should -BeFalse
    }

    It 'warns when there is no personal folder' {
        (Get-Result $results 'carlos.ruiz').Warnings -join ' ' | Should -Match 'not found: nothing to archive'
    }

    It 'logs every change with its reverse action' {
        $journal = Read-Journal $results[0]
        $changes = @($journal | Where-Object { $_.status -eq 'Succeeded' -and $_.target -eq 'ana.garcial' -and $_.action -ne 'RecordGroups' })
        $changes.action | Should -Be @('SetEnabled', 'SetDescription', 'RemoveGroupMember', 'RemoveGroupMember', 'MoveUser', 'MoveFolder')
        @($changes | Where-Object { $null -eq $_.undo }).Count | Should -Be 0
        ($changes | Where-Object action -eq 'MoveUser').undo.TargetOu | Should -Be 'OU=Sales,OU=Staff,DC=corp,DC=example,DC=com'
        ($changes | Where-Object action -eq 'SetEnabled').undo.Enabled | Should -BeTrue
    }

    It 'skips an account that is already offboarded' {
        (Get-Result $results 'pablo.ortiz').Status | Should -Be 'Skipped'
    }

    It 'never touches protected accounts or members of protected groups' {
        (Get-Result $results 'administrator').Message | Should -Be 'administrator is a protected account'
        (Get-Result $results 'adm.laura').Message | Should -Match 'protected group\(s\) Domain Admins'
        $directory.FindUser('adm.laura').enabled | Should -BeTrue
        $directory.GetUserGroups('adm.laura') | Should -Contain 'Domain Admins'
    }

    It 'rejects an EmployeeId that belongs to another account' {
        (Get-Result $results 'maria.garcia').Message | Should -Match 'belongs to carlos.ruiz'
        $directory.FindUser('maria.garcia').enabled | Should -BeTrue
    }

    It 'reports people who are not in the directory' {
        @($results | Where-Object EmployeeId -eq 'E9999')[0].Message | Should -Be 'No account found for EmployeeId E9999'
    }

    It 'does nothing more when run again' {
        $again = Invoke-TestOffboarding -Directory $directory
        @($again | Where-Object Status -eq 'Offboarded').Count | Should -Be 0
        @($again | Where-Object Status -eq 'Skipped').Count | Should -Be 3
    }
}

Describe 'Invoke-ADFlowOffboarding -DryRun and -WhatIf' {
    It 'plans without changing the directory or the folders' {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        Add-TestHomeFolder 'carlos.ruiz'
        $results = Invoke-TestOffboarding -Directory $directory -DryRun
        @($results | Where-Object Status -eq 'Planned').Count | Should -Be 2
        $directory.FindUser('carlos.ruiz').enabled | Should -BeTrue
        $directory.GetUserGroups('carlos.ruiz') | Should -Contain 'GG-Finance-Users'
        Test-Path -Path (Join-Path -Path $TestDrive -ChildPath 'home\carlos.ruiz') | Should -BeTrue
        @(Read-Journal $results[0] | Where-Object { $null -ne $_.undo }).Count | Should -Be 0
    }

    It 'previews with -WhatIf without changing anything' {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $results = Invoke-TestOffboarding -Directory $directory -Preview
        @($results | Where-Object Status -eq 'WhatIf').Count | Should -Be 2
        $directory.FindUser('ana.garcial').enabled | Should -BeTrue
    }
}

Describe 'Invoke-ADFlowOffboarding settings and failures' {
    It 'needs a leavers OU in the settings and in the directory' {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $local = Get-TestConfig
        $local.offboarding.ou = 'OU=Gone,DC=corp,DC=example,DC=com'
        { Invoke-TestOffboarding -Directory $directory -Config $local } | Should -Throw '*does not exist*'
        $local.offboarding = $null
        { Invoke-TestOffboarding -Directory $directory -Config $local } | Should -Throw '*offboarding.ou*'
    }

    It 'stops the steps of a person when one fails and says what can be undone' {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $directory | Add-Member -MemberType ScriptMethod -Name MoveUser -Force -Value { throw 'Access is denied' }
        $csv = Write-TestHireFile -Header 'SamAccountName' -Rows 'carlos.ruiz'
        $result = (Invoke-TestOffboarding -CsvPath $csv -Directory $directory)[0]
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'Move to .* failed: Access is denied'
        $result.Message | Should -Match '5 earlier step\(s\) can be undone'
        $directory.FindUser('carlos.ruiz').enabled | Should -BeFalse
    }

    It 'warns when no archive root is set and leaves the folder in place' {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        Add-TestHomeFolder 'maria.garcia'
        $local = Get-TestConfig
        $local.offboarding.archiveRoot = ''
        $csv = Write-TestHireFile -Header 'SamAccountName' -Rows 'maria.garcia'
        $result = (Invoke-TestOffboarding -CsvPath $csv -Directory $directory -Config $local)[0]
        $result.Status | Should -Be 'Offboarded'
        $result.Warnings -join ' ' | Should -Match 'archiveRoot is not set'
        Test-Path -Path (Join-Path -Path $TestDrive -ChildPath 'home\maria.garcia') | Should -BeTrue
    }
}
