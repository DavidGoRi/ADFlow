#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    # The account running the tests keeps full control, so TestDrive can be cleaned
    $operatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $operator = [ordered]@{ Name = 'operator'; Sid = $operatorSid }
    $userSid = 'S-1-5-21-1000-2000-3000-1500'

    function Get-TestConfig([string] $HomeRoot) {
        $local = Get-ADFlowConfig -Path $configPath
        $local.homeFolders.root = $HomeRoot
        $local.welcome = $null
        return $local
    }
    function Invoke-TestOnboarding {
        param([string] $CsvPath = $demoCsvPath, $Directory, $Config, [switch] $DryRun)
        return @(Invoke-ADFlowOnboarding -CsvPath $CsvPath -Config $Config -Directory $Directory `
                -LogPath (Join-Path -Path $TestDrive -ChildPath 'runs') -DryRun:$DryRun)
    }
}

Describe 'Get-ADFlowHomeFolderAcl' {
    It 'gives full control to SYSTEM, Administrators and the admins, and Modify to the user' {
        $acl = Get-ADFlowHomeFolderAcl -User ([ordered]@{ Name = 'ana.soto'; Sid = $userSid }) -Admins ([ordered]@{ Name = 'GG-IT-Admins'; Sid = 'S-1-5-21-1000-2000-3000-1200' })
        $acl.Count | Should -Be 4
        $acl[0].Sid | Should -Be 'S-1-5-18'
        $acl[1].Sid | Should -Be 'S-1-5-32-544'
        $acl[2].Identity | Should -Be 'GG-IT-Admins'
        @($acl | Where-Object { $_.Rights -eq 'FullControl' }).Count | Should -Be 3
        $acl[3] | Should -Not -BeNullOrEmpty
        $acl[3].Identity | Should -Be 'ana.soto'
        $acl[3].Rights | Should -Be 'Modify'
    }

    It 'does not repeat an admin' {
        $acl = Get-ADFlowHomeFolderAcl -User ([ordered]@{ Name = 'ana.soto'; Sid = $userSid }) -Admins ([ordered]@{ Name = 'Admins again'; Sid = 'S-1-5-32-544' })
        $acl.Count | Should -Be 3
    }
}

Describe 'New-ADFlowHomeFolder' {
    It 'creates the folder with only the given permissions, without inheritance' {
        $path = Join-Path -Path $TestDrive -ChildPath 'ana.soto'
        $acl = Get-ADFlowHomeFolderAcl -User ([ordered]@{ Name = 'ana.soto'; Sid = $userSid }) -Admins $operator
        New-ADFlowHomeFolder -Path $path -Acl $acl
        $summary = Get-ADFlowFolderAclSummary -Path $path
        $summary | Should -Contain 'S-1-5-18=FullControl'
        $summary | Should -Contain 'S-1-5-32-544=FullControl'
        $summary | Should -Contain "$operatorSid=FullControl"
        $summary | Should -Contain "$userSid=Modify"
        @($summary | Where-Object { $_ -like '*(inherited)' }).Count | Should -Be 0
    }

    It 'accepts the permissions read back from JSON' {
        $path = Join-Path -Path $TestDrive -ChildPath 'from-json'
        $acl = Get-ADFlowHomeFolderAcl -User ([ordered]@{ Name = 'eva'; Sid = $userSid }) -Admins $operator
        $json = ConvertTo-Json -InputObject $acl -Depth 3 | ConvertFrom-Json
        New-ADFlowHomeFolder -Path $path -Acl $json
        Get-ADFlowFolderAclSummary -Path $path | Should -Contain "$userSid=Modify"
    }

    It 'refuses an existing folder, a missing root and an entry without SID' {
        $acl = Get-ADFlowHomeFolderAcl -User ([ordered]@{ Name = 'x'; Sid = $userSid }) -Admins $operator
        $existing = Join-Path -Path $TestDrive -ChildPath 'existing'
        [void] [IO.Directory]::CreateDirectory($existing)
        { New-ADFlowHomeFolder -Path $existing -Acl $acl } | Should -Throw '*already exists*'
        { New-ADFlowHomeFolder -Path (Join-Path -Path $TestDrive -ChildPath 'no\root\x') -Acl $acl } | Should -Throw '*root*does not exist*'
        $noSid = Get-ADFlowHomeFolderAcl -User ([ordered]@{ Name = 'x'; Sid = $null }) -Admins $operator
        { New-ADFlowHomeFolder -Path (Join-Path -Path $TestDrive -ChildPath 'nosid') -Acl $noSid } | Should -Throw '*has no SID*'
    }

    It 'does nothing with -WhatIf' {
        $path = Join-Path -Path $TestDrive -ChildPath 'whatif'
        $acl = Get-ADFlowHomeFolderAcl -User ([ordered]@{ Name = 'x'; Sid = $userSid }) -Admins $operator
        New-ADFlowHomeFolder -Path $path -Acl $acl -WhatIf
        Test-Path -Path $path | Should -BeFalse
    }
}

Describe 'Remove-ADFlowEmptyFolder' {
    It 'deletes an empty folder and keeps one with files' {
        $empty = Join-Path -Path $TestDrive -ChildPath 'empty'
        [void] [IO.Directory]::CreateDirectory($empty)
        Remove-ADFlowEmptyFolder -Path $empty
        Test-Path -Path $empty | Should -BeFalse

        $full = Join-Path -Path $TestDrive -ChildPath 'full'
        [void] [IO.Directory]::CreateDirectory($full)
        [IO.File]::WriteAllText((Join-Path -Path $full -ChildPath 'cv.docx'), 'x')
        { Remove-ADFlowEmptyFolder -Path $full } | Should -Throw '*not empty*'
        Test-Path -Path (Join-Path -Path $full -ChildPath 'cv.docx') | Should -BeTrue
    }
}

Describe 'Personal folders at onboarding' {
    BeforeAll {
        $homeRoot = Join-Path -Path $TestDrive -ChildPath 'home'
        [void] [IO.Directory]::CreateDirectory($homeRoot)
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $results = Invoke-TestOnboarding -Directory $directory -Config (Get-TestConfig $homeRoot)
    }

    It 'creates one folder per new account' {
        @(Get-ChildItem -Path $homeRoot -Directory).Count | Should -Be 8
        (@($results | Where-Object EmployeeId -eq 'E1002')[0]).HomeFolder | Should -Be (Join-Path $homeRoot 'jose.pena')
    }

    It 'gives the user Modify and the admin group full control, by SID' {
        $summary = Get-ADFlowFolderAclSummary -Path (Join-Path $homeRoot 'jose.pena')
        $summary | Should -Contain "$($directory.GetUserSid('jose.pena'))=Modify"
        $summary | Should -Contain "$($directory.GetGroupSid('GG-IT-Admins'))=FullControl"
        $summary | Should -Contain "$operatorSid=FullControl"
    }

    It 'stores the folder and the drive in the account' {
        $user = $directory.FindUser('jose.pena')
        $user.homeDirectory | Should -Be (Join-Path $homeRoot 'jose.pena')
        $user.homeDrive | Should -Be 'H:'
    }

    It 'logs the permissions and how to undo the folder' {
        $journal = @(Get-Content -Path (Join-Path $results[0].RunFolder 'audit.jsonl') -Encoding UTF8 | ConvertFrom-Json)
        $entry = @($journal | Where-Object { $_.action -eq 'CreateHomeFolder' -and $_.target -eq 'jose.pena' })[0]
        $entry.status | Should -Be 'Succeeded'
        $entry.undo.Action | Should -Be 'RemoveFolder'
        @($entry.details.Acl | Where-Object { $_.Rights -eq 'Modify' })[0].Identity | Should -Be 'jose.pena'
    }

    It 'leaves an existing folder alone, with a warning' {
        [void] [IO.Directory]::CreateDirectory((Join-Path $homeRoot 'luis.soto'))
        $csv = Write-TestHireFile -Rows 'E7,Luis,Soto,IT,Helpdesk Technician,,'
        $result = (Invoke-TestOnboarding -CsvPath $csv -Directory $directory -Config (Get-TestConfig $homeRoot))[0]
        $result.Status | Should -Be 'Created'
        $result.HomeFolder | Should -BeNullOrEmpty
        $result.Warnings -join ' ' | Should -Match 'already exists'
    }

    It 'warns once per row when the root is not reachable' {
        $csv = Write-TestHireFile -Rows 'E8,Eva,Mora,IT,Helpdesk Technician,,'
        $result = (Invoke-TestOnboarding -CsvPath $csv -Directory $directory -Config (Get-TestConfig (Join-Path $TestDrive 'missing')))[0]
        $result.Status | Should -Be 'Created'
        $result.Warnings -join ' ' | Should -Match 'not reachable'
    }

    It 'plans the folder in a dry run without creating it' {
        $dryDirectory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $dryRoot = Join-Path -Path $TestDrive -ChildPath 'dry-home'
        [void] [IO.Directory]::CreateDirectory($dryRoot)
        $planned = Invoke-TestOnboarding -Directory $dryDirectory -Config (Get-TestConfig $dryRoot) -DryRun
        @(Get-ChildItem -Path $dryRoot).Count | Should -Be 0
        $journal = @(Get-Content -Path (Join-Path $planned[0].RunFolder 'audit.jsonl') -Encoding UTF8 | ConvertFrom-Json)
        @($journal | Where-Object { $_.action -eq 'CreateHomeFolder' -and $_.status -eq 'Planned' }).Count | Should -Be 8
    }

    It 'removes the empty folders on rollback and keeps the ones with files' {
        [IO.File]::WriteAllText((Join-Path $homeRoot 'jose.pena\notes.txt'), 'fictitious')
        $undo = @(Undo-ADFlowRun -RunFolder $results[0].RunFolder -Directory $directory -LogPath (Join-Path $TestDrive 'runs'))
        Test-Path -Path (Join-Path $homeRoot 'maria.garcial') | Should -BeFalse
        Test-Path -Path (Join-Path $homeRoot 'jose.pena\notes.txt') | Should -BeTrue
        $kept = @($undo | Where-Object Status -eq 'Failed')
        $kept.Count | Should -Be 1
        $kept[0].Message | Should -Match 'not empty'
    }
}

Describe 'Simulated directory SIDs' {
    It 'gives every user and group a unique SID that survives a save' {
        $state = Join-Path -Path $TestDrive -ChildPath 'sids.json'
        $first = Open-ADFlowMockDirectory -SeedPath $seedPath -StatePath $state
        $sids = @($first.Users.Values | ForEach-Object { $_.sid }) + @($first.GroupSids.Values)
        @($sids | Sort-Object -Unique).Count | Should -Be $sids.Count
        $sids | ForEach-Object { $_ | Should -Match '^S-1-5-21-1000-2000-3000-\d+$' }
        $first.Save()
        $second = Open-ADFlowMockDirectory -SeedPath $seedPath -StatePath $state
        $second.GetUserSid('carlos.ruiz') | Should -Be $first.GetUserSid('carlos.ruiz')
        $second.GetGroupSid('GG-IT-Admins') | Should -Be $first.GetGroupSid('GG-IT-Admins')
    }

    It 'gives new users the next free SID' {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $next = $directory.NextRid
        [void] $directory.NewUser(@{ SamAccountName = 'new.user'; Ou = 'OU=IT,OU=Staff,DC=corp,DC=example,DC=com'; Password = (Get-ADFlowRandomPassword) })
        $directory.GetUserSid('new.user') | Should -Be "S-1-5-21-1000-2000-3000-$next"
    }
}
