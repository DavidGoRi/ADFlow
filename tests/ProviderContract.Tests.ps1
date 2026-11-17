#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The same checks for every directory provider: whatever ADFlow relies on must
# behave the same in the simulated directory and in Active Directory (here,
# against the simulated ActiveDirectory module of FakeActiveDirectory.psm1).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'FakeActiveDirectory.psm1') -Force

    function Open-TestDirectory([string] $Provider) {
        if ($Provider -eq 'Mock') { return Open-ADFlowMockDirectory -SeedPath $seedPath }
        Initialize-FakeActiveDirectory -SeedPath $seedPath
        return Open-ADFlowADDirectory -Server 'dc01.corp.example.com'
    }
    function Get-TestSpec([string] $Sam = 'eva.mora', [string] $Name = 'Eva Mora') {
        return @{
            SamAccountName        = $Sam
            UserPrincipalName     = "$Sam@corp.example.com"
            GivenName             = ($Name -split ' ')[0]
            Surname               = ($Name -split ' ', 2)[1]
            DisplayName           = $Name
            EmployeeId            = 'E5000'
            Department            = 'IT'
            Title                 = 'Helpdesk Technician'
            Ou                    = 'OU=IT,OU=Staff,DC=corp,DC=example,DC=com'
            Password              = Get-ADFlowRandomPassword
            Enabled               = $true
            ChangePasswordAtLogon = $true
        }
    }
    $staffIt = 'OU=IT,OU=Staff,DC=corp,DC=example,DC=com'
    $leavers = 'OU=Leavers,DC=corp,DC=example,DC=com'
}

Describe 'Directory provider <_>' -ForEach @('Mock', 'ActiveDirectory') {
    BeforeEach {
        $directory = Open-TestDirectory $_
    }

    It 'has the expected name' {
        $directory.Name | Should -Be $_
    }

    It 'finds users by name, by UPN prefix and by employee id' {
        $directory.FindUser('maria.garcia').employeeId | Should -Be 'E0901'
        $directory.FindUser('MARIA.GARCIA') | Should -Not -BeNullOrEmpty
        $directory.FindUser('nobody') | Should -BeNullOrEmpty
        $directory.FindUserByEmployeeId('E0907').samAccountName | Should -Be 'laura.sanchez'
        $directory.FindUserByEmployeeId('E9999') | Should -BeNullOrEmpty
    }

    It 'treats wildcards and parentheses in names as plain text' {
        $directory.FindUser('*') | Should -BeNullOrEmpty
        $directory.FindUser('maria*') | Should -BeNullOrEmpty
        $directory.FindUser('x)(sAMAccountName=*') | Should -BeNullOrEmpty
        $directory.FindUserByEmployeeId('*') | Should -BeNullOrEmpty
    }

    It 'reports the OU, state and description of a user' {
        $user = $directory.FindUser('pablo.ortiz')
        $user.ou | Should -Be $leavers
        $user.enabled | Should -BeFalse
        $user.description | Should -BeLike 'Left on 2026-10-31*'
    }

    It 'knows which OUs and groups exist' {
        $directory.TestOu($staffIt) | Should -BeTrue
        $directory.TestOu('OU=Nowhere,DC=corp,DC=example,DC=com') | Should -BeFalse
        $directory.TestGroup('GG-IT-Admins') | Should -BeTrue
        $directory.TestGroup('GG-Nope') | Should -BeFalse
    }

    It 'creates enabled users that must change their password' {
        [void] $directory.NewUser((Get-TestSpec))
        $user = $directory.FindUser('eva.mora')
        $user.ou | Should -Be $staffIt
        $user.enabled | Should -BeTrue
        $user.employeeId | Should -Be 'E5000'
        $user.displayName | Should -Be 'Eva Mora'
        $directory.GetUserSid('eva.mora') | Should -Match '^S-1-5-21-[\d-]+$'
    }

    It 'refuses a user name that already exists' {
        { $directory.NewUser((Get-TestSpec -Sam 'maria.garcia')) } | Should -Throw
    }

    It 'manages group membership' {
        [void] $directory.NewUser((Get-TestSpec))
        $directory.AddGroupMember('GG-VPN-Users', 'eva.mora')
        $directory.GetGroupMembers('GG-VPN-Users') | Should -Contain 'eva.mora'
        $directory.GetUserGroups('eva.mora') | Should -Contain 'GG-VPN-Users'
        $directory.RemoveGroupMember('GG-VPN-Users', 'eva.mora')
        $directory.GetGroupMembers('GG-VPN-Users') | Should -Not -Contain 'eva.mora'
        $directory.GetGroupSid('GG-VPN-Users') | Should -Match '^S-1-5-21-[\d-]+$'
    }

    It 'lists Domain Users among the groups of an account' {
        $directory.GetUserGroups('carlos.ruiz') | Should -Be @('Domain Users', 'GG-AllStaff', 'GG-ERP-Users', 'GG-Finance-Users')
    }

    It 'enables, disables, describes and moves accounts' {
        $directory.SetEnabled('carlos.ruiz', $false)
        $directory.FindUser('carlos.ruiz').enabled | Should -BeFalse
        $directory.SetEnabled('carlos.ruiz', $true)
        $directory.FindUser('carlos.ruiz').enabled | Should -BeTrue
        $directory.SetDescription('carlos.ruiz', 'Left on 2026-11-30')
        $directory.FindUser('carlos.ruiz').description | Should -Be 'Left on 2026-11-30'
        $directory.SetDescription('carlos.ruiz', '')
        $directory.FindUser('carlos.ruiz').description | Should -BeNullOrEmpty
        $directory.MoveUser('carlos.ruiz', $leavers)
        $directory.FindUser('carlos.ruiz').ou | Should -Be $leavers
    }

    It 'deletes accounts and their memberships' {
        [void] $directory.NewUser((Get-TestSpec))
        $directory.AddGroupMember('GG-VPN-Users', 'eva.mora')
        $directory.RemoveUser('eva.mora')
        $directory.FindUser('eva.mora') | Should -BeNullOrEmpty
        $directory.GetGroupMembers('GG-VPN-Users') | Should -Not -Contain 'eva.mora'
    }

    It 'fails on unknown users and groups' {
        { $directory.AddGroupMember('GG-Nope', 'carlos.ruiz') } | Should -Throw
        { $directory.AddGroupMember('GG-VPN-Users', 'nobody') } | Should -Throw
        { $directory.SetEnabled('nobody', $false) } | Should -Throw
        { $directory.MoveUser('carlos.ruiz', 'OU=Nowhere,DC=corp,DC=example,DC=com') } | Should -Throw
    }
}

Describe 'The whole cycle with provider <_>' -ForEach @('Mock', 'ActiveDirectory') {
    BeforeAll {
        $directory = Open-TestDirectory $_
        $config = Get-ADFlowConfig -Path $configPath
        $config.homeFolders.root = ''
        $config.welcome = $null
        $logPath = Join-Path $TestDrive "runs-$_"
        $carlosBefore = @($directory.GetUserGroups('carlos.ruiz')) -join ','
    }

    It 'onboards the demo file with the same user names' {
        $results = @(Invoke-ADFlowOnboarding -CsvPath $demoCsvPath -Config $config -Directory $directory -LogPath $logPath)
        @($results | Where-Object Status -eq 'Created').Count | Should -Be 8
        @($results | Where-Object Status -eq 'Created' | ForEach-Object SamAccountName) | Should -Be @(
            'maria.garcial', 'jose.pena', 'pedro.delafuente', 'inigo.martinezaragon', 'ana.garcia2', 'zoe.oconnor', 'maximiliano.fernande', 'jose.penam')
        $directory.GetUserGroups('jose.pena') | Should -Contain 'GG-ERP-Users'
        $directory.FindUser('jose.pena').ou | Should -Be 'OU=Finance,OU=Staff,DC=corp,DC=example,DC=com'
    }

    It 'offboards the demo leavers and undoes it exactly' {
        $done = @(Invoke-ADFlowOffboarding -CsvPath (Join-Path $repoRoot 'demo\leavers.csv') -Config $config -Directory $directory -LogPath $logPath)
        @($done | Where-Object Status -eq 'Offboarded').Count | Should -Be 2
        $directory.FindUser('carlos.ruiz').enabled | Should -BeFalse
        $directory.GetUserGroups('carlos.ruiz') | Should -Be @('Domain Users')

        $undo = @(Undo-ADFlowRun -RunFolder $done[0].RunFolder -Directory $directory -LogPath $logPath)
        @($undo | Where-Object Status -ne 'Reverted').Count | Should -Be 0
        @($directory.GetUserGroups('carlos.ruiz')) -join ',' | Should -Be $carlosBefore
        $directory.FindUser('carlos.ruiz').enabled | Should -BeTrue
        $directory.FindUser('carlos.ruiz').ou | Should -Be 'OU=Finance,OU=Staff,DC=corp,DC=example,DC=com'
    }
}

AfterAll {
    Remove-Module -Name FakeActiveDirectory -Force -ErrorAction SilentlyContinue
}
