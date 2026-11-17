#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'FakeActiveDirectory.psm1') -Force
    $labScript = Join-Path $repoRoot 'tools\New-ADFlowLab.ps1'
}

Describe 'tools/New-ADFlowLab.ps1' {
    BeforeEach {
        Initialize-FakeActiveDirectory
    }

    It 'fills an empty lab domain from the seed' {
        $summary = & $labScript -SkipShares
        $summary.OUs | Should -Be 9
        $summary.Users | Should -Be 8
        (Get-FakeADState).Ous.Contains('OU=IT,OU=Staff,DC=corp,DC=example,DC=com') | Should -BeTrue
        (Get-FakeADState).Groups['GG-IT-Admins'].DistinguishedName | Should -Be 'CN=GG-IT-Admins,OU=Groups,DC=corp,DC=example,DC=com'
        (Get-FakeADState).Groups['GG-Finance-Users'].Members.Contains('carlos.ruiz') | Should -BeTrue
        (Get-FakeADState).Users['pablo.ortiz'].Enabled | Should -BeFalse
        (Get-FakeADState).Users['carlos.ruiz'].EmployeeID | Should -Be 'E0904'
    }

    It 'creates parents before children' {
        [void] (& $labScript -SkipShares)
        $order = @((Get-FakeADState).Calls | Where-Object Command -eq 'New-ADOrganizationalUnit' | ForEach-Object { $_.Parameters.Name })
        [array]::IndexOf($order, 'Staff') | Should -BeLessThan ([array]::IndexOf($order, 'IT'))
    }

    It 'gives every sample user a random password' {
        [void] (& $labScript -SkipShares)
        $passwords = @((Get-FakeADState).Calls | Where-Object Command -eq 'New-ADUser' | ForEach-Object { ConvertFrom-TestSecureString -Secure $_.Parameters.AccountPassword })
        $passwords.Count | Should -Be 8
        @($passwords | Sort-Object -Unique).Count | Should -Be 8
        $passwords | ForEach-Object { $_.Length | Should -Be 24 }
    }

    It 'leaves alone what already exists when run again' {
        [void] (& $labScript -SkipShares)
        $again = & $labScript -SkipShares
        $again.OUs + $again.Groups + $again.Users + $again.Memberships | Should -Be 0
    }

    It 'changes nothing with -WhatIf' {
        [void] (& $labScript -SkipShares -WhatIf)
        (Get-FakeADState).Users.Count | Should -Be 0
    }

    It 'refuses a seed of another domain' {
        $other = Join-Path $TestDrive 'other.json'
        [IO.File]::WriteAllText($other, '{ "ous": [ "OU=Staff,DC=contoso,DC=test" ], "groups": [], "users": [] }')
        { & $labScript -SeedPath $other -SkipShares } | Should -Throw '*lab domain*'
    }

    It 'works with ADFlow.ps1 -Provider ActiveDirectory' {
        [void] (& $labScript -SkipShares)
        $logs = Join-Path $TestDrive 'runs-entry'
        $planned = & (Join-Path $repoRoot 'ADFlow.ps1') -Action Onboard -CsvPath $demoCsvPath -Provider ActiveDirectory `
            -Server 'dc01.corp.example.com' -HomeRoot (Join-Path $TestDrive 'no-share') -LogPath $logs -DryRun -PassThru 6> $null
        @($planned | Where-Object Status -eq 'Planned').Count | Should -Be 8
        ([IO.File]::ReadAllText((Join-Path $planned[0].RunFolder 'summary.json')) | ConvertFrom-Json).provider | Should -Be 'ActiveDirectory'
        # A dry run creates nothing: the only New-ADUser calls are the lab script's
        @((Get-FakeADState).Calls | Where-Object Command -eq 'New-ADUser').Count | Should -Be 8
    }

    It 'gives a lab where the whole ADFlow cycle works' {
        [void] (& $labScript -SkipShares)
        $directory = Open-ADFlowADDirectory
        $config = Get-ADFlowConfig -Path $configPath
        $config.homeFolders.root = ''
        $config.welcome = $null
        $results = @(Invoke-ADFlowOnboarding -CsvPath $demoCsvPath -Config $config -Directory $directory -LogPath (Join-Path $TestDrive 'runs'))
        @($results | Where-Object Status -eq 'Created').Count | Should -Be 8
        # GG-CRM-Users is not in the seed, as in the simulated directory
        (@($results | Where-Object EmployeeId -eq 'E1003')[0]).Warnings -join ' ' | Should -Match 'GG-CRM-Users'
    }
}

AfterAll {
    Remove-Module -Name FakeActiveDirectory -Force -ErrorAction SilentlyContinue
}
