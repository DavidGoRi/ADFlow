#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $config = Get-ADFlowConfig -Path $configPath

    function Write-TestConfig([string] $Json) {
        $path = Join-Path -Path $TestDrive -ChildPath 'config.json'
        [IO.File]::WriteAllText($path, $Json)
        return $path
    }
}

Describe 'Get-ADFlowConfig' {
    It 'loads the sample settings' {
        $config.domain.upnSuffix | Should -Be 'corp.example.com'
        @($config.departments.PSObject.Properties).Count | Should -BeGreaterThan 0
    }

    It 'fails when the file does not exist' {
        { Get-ADFlowConfig -Path (Join-Path -Path $TestDrive -ChildPath 'missing.json') } | Should -Throw '*not found*'
    }

    It 'fails on invalid JSON' {
        { Get-ADFlowConfig -Path (Write-TestConfig '{ not json') } | Should -Throw '*not valid JSON*'
    }

    It 'lists every problem of an invalid file' {
        $path = Write-TestConfig '{ "domain": {}, "departments": { "IT": { "ou": "CN=IT" } }, "roles": { "Admin": [ "" ] }, "password": { "length": 8 } }'
        $message = { Get-ADFlowConfig -Path $path } | Should -Throw -PassThru
        $message.Exception.Message | Should -Match 'upnSuffix'
        $message.Exception.Message | Should -Match "department 'IT'"
        $message.Exception.Message | Should -Match "role 'Admin'"
        $message.Exception.Message | Should -Match 'password.length'
    }
}

Describe 'Get-ADFlowDepartmentOu' {
    It 'finds a department regardless of case, accents and spaces' {
        Get-ADFlowDepartmentOu -Config $config -Department '  human   RESOURCES ' |
            Should -Be 'OU=Human Resources,OU=Staff,DC=corp,DC=example,DC=com'
    }

    It 'matches accented names in the settings' {
        $local = Get-ADFlowConfig -Path (Write-TestConfig '{ "domain": { "upnSuffix": "corp.example.com" }, "departments": { "Administración": { "ou": "OU=Admin,DC=corp,DC=example,DC=com" } } }')
        Get-ADFlowDepartmentOu -Config $local -Department 'administracion' | Should -Be 'OU=Admin,DC=corp,DC=example,DC=com'
    }

    It 'returns nothing for an unknown department' {
        Get-ADFlowDepartmentOu -Config $config -Department 'Legal' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ADFlowGroupAssignment' {
    It 'gives the default groups plus the groups of the role' {
        $assignment = Get-ADFlowGroupAssignment -Config $config -Title 'helpdesk technician'
        $assignment.RoleFound | Should -BeTrue
        $assignment.Groups | Should -Be @('GG-AllStaff', 'GG-IT-Helpdesk', 'GG-VPN-Users')
    }

    It 'gives only the default groups to an unknown role' {
        $assignment = Get-ADFlowGroupAssignment -Config $config -Title 'Astronaut'
        $assignment.RoleFound | Should -BeFalse
        $assignment.Groups | Should -Be @('GG-AllStaff')
    }

    It 'does not repeat a group that is both default and in the role' {
        $local = Get-ADFlowConfig -Path (Write-TestConfig '{ "domain": { "upnSuffix": "corp.example.com" }, "departments": { "IT": { "ou": "OU=IT,DC=corp,DC=example,DC=com" } }, "defaultGroups": [ "GG-AllStaff" ], "roles": { "Tech": [ "gg-allstaff", "GG-Tech" ] } }')
        (Get-ADFlowGroupAssignment -Config $local -Title 'Tech').Groups | Should -Be @('GG-AllStaff', 'GG-Tech')
    }

    It 'works without default groups' {
        $local = Get-ADFlowConfig -Path (Write-TestConfig '{ "domain": { "upnSuffix": "corp.example.com" }, "departments": { "IT": { "ou": "OU=IT,DC=corp,DC=example,DC=com" } } }')
        @((Get-ADFlowGroupAssignment -Config $local -Title 'Tech').Groups).Count | Should -Be 0
    }
}
