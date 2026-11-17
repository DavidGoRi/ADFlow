#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')

    function Get-TestSpec([string] $Sam = 'eva.mora') {
        return @{
            SamAccountName        = $Sam
            UserPrincipalName     = "$Sam@corp.example.com"
            DisplayName           = 'Eva Mora'
            EmployeeId            = 'E5000'
            Ou                    = 'OU=IT,OU=Staff,DC=corp,DC=example,DC=com'
            Password              = Get-ADFlowRandomPassword
            Enabled               = $true
            ChangePasswordAtLogon = $true
        }
    }
}

Describe 'Open-ADFlowMockDirectory' {
    BeforeEach {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
    }

    It 'loads the seed' {
        $directory.Name | Should -Be 'Mock'
        $directory.FindUser('maria.garcia').employeeId | Should -Be 'E0901'
        $directory.TestOu('OU=IT,OU=Staff,DC=corp,DC=example,DC=com') | Should -BeTrue
        $directory.TestGroup('GG-AllStaff') | Should -BeTrue
    }

    It 'looks users up without regard to case' {
        $directory.FindUser('MARIA.GARCIA') | Should -Not -BeNullOrEmpty
        $directory.TestGroup('gg-allstaff') | Should -BeTrue
    }

    It 'counts a UPN prefix as a taken name' {
        $directory.Users['other'] = [pscustomobject]@{ samAccountName = 'other'; userPrincipalName = 'luis.soto@corp.example.com' }
        $directory.FindUser('luis.soto').samAccountName | Should -Be 'other'
    }

    It 'finds users by employee id' {
        $directory.FindUserByEmployeeId('E0907').samAccountName | Should -Be 'laura.sanchez'
        $directory.FindUserByEmployeeId('E9999') | Should -BeNullOrEmpty
    }

    It 'creates users without storing the password' {
        [void] $directory.NewUser((Get-TestSpec))
        $user = $directory.FindUser('eva.mora')
        $user.enabled | Should -BeTrue
        $user.changePasswordAtLogon | Should -BeTrue
        $user.passwordSet | Should -BeTrue
        $user.PSObject.Properties.Name | Should -Not -Contain 'password'
    }

    It 'refuses a user that already exists, an unknown OU or an unknown manager' {
        { $directory.NewUser((Get-TestSpec -Sam 'maria.garcia')) } | Should -Throw '*already exists*'
        $spec = Get-TestSpec; $spec.Ou = 'OU=Nowhere,DC=corp,DC=example,DC=com'
        { $directory.NewUser($spec) } | Should -Throw '*does not exist*'
        $spec = Get-TestSpec; $spec.Manager = 'nobody'
        { $directory.NewUser($spec) } | Should -Throw '*manager*'
    }

    It 'adds group members once' {
        [void] $directory.NewUser((Get-TestSpec))
        $directory.AddGroupMember('GG-IT-Helpdesk', 'eva.mora')
        $directory.AddGroupMember('GG-IT-Helpdesk', 'eva.mora')
        @($directory.GetGroupMembers('GG-IT-Helpdesk') | Where-Object { $_ -eq 'eva.mora' }).Count | Should -Be 1
    }

    It 'refuses unknown groups and users' {
        { $directory.AddGroupMember('GG-Nope', 'maria.garcia') } | Should -Throw '*group*'
        { $directory.AddGroupMember('GG-AllStaff', 'nobody') } | Should -Throw '*user*'
    }
}

Describe 'Simulated directory state' {
    It 'saves the changes and loads them instead of the seed' {
        $state = Join-Path -Path $TestDrive -ChildPath 'state\directory.json'
        $first = Open-ADFlowMockDirectory -SeedPath $seedPath -StatePath $state
        [void] $first.NewUser((Get-TestSpec))
        $first.AddGroupMember('GG-AllStaff', 'eva.mora')
        $first.Save()

        $second = Open-ADFlowMockDirectory -SeedPath $seedPath -StatePath $state
        $second.FindUser('eva.mora') | Should -Not -BeNullOrEmpty
        $second.GetGroupMembers('GG-AllStaff') | Should -Contain 'eva.mora'
        $second.TestOu('OU=Leavers,DC=corp,DC=example,DC=com') | Should -BeTrue
        [IO.File]::ReadAllText($state) | Should -Not -Match 'password"'
    }

    It 'does not touch the seed file' {
        $before = [IO.File]::ReadAllText($seedPath)
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        [void] $directory.NewUser((Get-TestSpec))
        $directory.Save()
        [IO.File]::ReadAllText($seedPath) | Should -BeExactly $before
    }
}
