#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'FakeActiveDirectory.psm1') -Force
    function Get-Call([string] $Command) { return @((Get-FakeADState).Calls | Where-Object Command -eq $Command) }
}

Describe 'LDAP and DN helpers' {
    It 'escapes the special characters of LDAP filters' {
        ConvertTo-ADFlowLdapValue -Value 'a*b(c)d\e' | Should -BeExactly 'a\2ab\28c\29d\5ce'
        ConvertTo-ADFlowLdapValue -Value 'maría.peña' | Should -BeExactly 'maría.peña'
    }

    It 'finds the parent of a DN, also with escaped commas' {
        Get-ADFlowParentDn -DistinguishedName 'CN=Ana Soto,OU=IT,DC=corp,DC=example,DC=com' | Should -Be 'OU=IT,DC=corp,DC=example,DC=com'
        Get-ADFlowParentDn -DistinguishedName 'CN=Soto\, Ana,OU=IT,DC=corp,DC=example,DC=com' | Should -Be 'OU=IT,DC=corp,DC=example,DC=com'
    }
}

Describe 'Open-ADFlowADDirectory' {
    BeforeEach {
        Initialize-FakeActiveDirectory -SeedPath $seedPath
    }

    It 'passes the server and the credential to every cmdlet' {
        $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'CORP\adflow-svc', (Get-ADFlowRandomPassword)
        $directory = Open-ADFlowADDirectory -Server 'dc01.corp.example.com' -Credential $credential
        [void] $directory.FindUser('carlos.ruiz')
        $directory.SetEnabled('carlos.ruiz', $false)
        [void] $directory.GetUserGroups('carlos.ruiz')
        (Get-FakeADState).Calls.Count | Should -BeGreaterThan 3
        foreach ($call in (Get-FakeADState).Calls) {
            $call.Parameters.Server | Should -Be 'dc01.corp.example.com' -Because $call.Command
            $call.Parameters.Credential.UserName | Should -Be 'CORP\adflow-svc' -Because $call.Command
        }
    }

    It 'uses the default domain controller when no server is given' {
        $directory = Open-ADFlowADDirectory
        [void] $directory.FindUser('carlos.ruiz')
        @((Get-FakeADState).Calls | Where-Object { $_.Parameters.ContainsKey('Server') }).Count | Should -Be 0
        $directory.Domain | Should -Be 'corp.example.com'
        $directory.HomeFolderAdmins.Count | Should -Be 0
    }

    It 'explains how to install the module when it is missing' -Skip:([bool] (Get-Module -ListAvailable -Name ActiveDirectory)) {
        $source = Join-Path $repoRoot 'src\ADDirectory.ps1'
        # A new process, where the simulated module of the other tests is not loaded
        $job = Start-Job -ScriptBlock {
            . $using:source
            try { Open-ADFlowADDirectory; 'no error' } catch { $_.Exception.Message }
        }
        $message = $job | Wait-Job -Timeout 60 | Receive-Job
        $job | Remove-Job -Force
        $message | Should -Match 'Add-WindowsCapability'
    }
}

Describe 'Active Directory provider details' {
    BeforeEach {
        Initialize-FakeActiveDirectory -SeedPath $seedPath
        $directory = Open-ADFlowADDirectory
        $spec = @{
            SamAccountName = 'ana.soto2'; DisplayName = 'Ana Soto'; Ou = 'OU=IT,OU=Staff,DC=corp,DC=example,DC=com'
            Password = Get-ADFlowRandomPassword; Enabled = $true; ChangePasswordAtLogon = $true
            UserPrincipalName = 'ana.soto2@corp.example.com'; Mail = 'ana.soto2@corp.example.com'; Manager = 'laura.sanchez'
            HomeDirectory = $null; Department = ''
        }
    }

    It 'creates the account with a secure password to change at the first logon' {
        [void] $directory.NewUser($spec)
        $call = (Get-Call 'New-ADUser')[0].Parameters
        $call.AccountPassword | Should -BeOfType [securestring]
        $call.ChangePasswordAtLogon | Should -BeTrue
        $call.Enabled | Should -BeTrue
        $call.EmailAddress | Should -Be 'ana.soto2@corp.example.com'
        $call.Manager | Should -Be 'laura.sanchez'
        $call.Path | Should -Be 'OU=IT,OU=Staff,DC=corp,DC=example,DC=com'
    }

    It 'leaves empty values out of New-ADUser' {
        [void] $directory.NewUser($spec)
        $call = (Get-Call 'New-ADUser')[0].Parameters
        $call.ContainsKey('HomeDirectory') | Should -BeFalse
        $call.ContainsKey('Department') | Should -BeFalse
    }

    It 'adds the user name to the CN when the OU already has someone with that name' {
        $spec.DisplayName = 'María García Sanz'   # the CN of maria.garcia
        [void] $directory.NewUser($spec)
        (Get-Call 'New-ADUser')[0].Parameters.Name | Should -Be 'María García Sanz (ana.soto2)'
        $directory.FindUser('ana.soto2').displayName | Should -Be 'María García Sanz'
    }

    It 'never asks for confirmation' {
        [void] $directory.NewUser($spec)
        $directory.AddGroupMember('GG-VPN-Users', 'ana.soto2')
        $directory.RemoveGroupMember('GG-VPN-Users', 'ana.soto2')
        $directory.RemoveUser('ana.soto2')
        (Get-Call 'Remove-ADGroupMember')[0].Parameters.Confirm | Should -BeFalse
        (Get-Call 'Remove-ADUser')[0].Parameters.Confirm | Should -BeFalse
    }

    It 'clears the description instead of writing an empty one' {
        $directory.SetDescription('carlos.ruiz', '')
        (Get-Call 'Set-ADUser')[0].Parameters.Clear | Should -Be 'description'
    }

    It 'escapes the values it searches for' {
        [void] $directory.FindUser('a*(b)')
        (Get-Call 'Get-ADUser')[0].Parameters.LDAPFilter | Should -Match 'sAMAccountName=a\\2a\\28b\\29\)'
    }
}

AfterAll {
    Remove-Module -Name FakeActiveDirectory -Force -ErrorAction SilentlyContinue
}
