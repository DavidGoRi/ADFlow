#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $config = Get-ADFlowConfig -Path $configPath
}

Describe 'Import-ADFlowHireFile' {
    It 'reads the demo file, separated by semicolons, with its accents' {
        $rows = @(Import-ADFlowHireFile -Path $demoCsvPath -Config $config)
        $rows.Count | Should -Be 12
        $rows[0].FirstName | Should -BeExactly 'María José'
        $rows[0].Row | Should -Be 2
        $rows[0].StartDate | Should -Be ([datetime] '2026-12-01')
    }

    It 'reads a file separated by commas' {
        $path = Write-TestHireFile -Rows 'E1,Ana,Soto,IT,Helpdesk Technician,,'
        $row = Import-ADFlowHireFile -Path $path -Config $config
        $row.LastName | Should -Be 'Soto'
        $row.Errors | Should -BeNullOrEmpty
    }

    It 'trims the values' {
        $path = Write-TestHireFile -Rows 'E1,  Ana ,Soto,IT,Helpdesk Technician,,'
        (Import-ADFlowHireFile -Path $path -Config $config).FirstName | Should -BeExactly 'Ana'
    }

    It 'works without the optional columns' {
        $path = Write-TestHireFile -Header 'EmployeeId,FirstName,LastName,Department,Title' -Rows 'E1,Ana,Soto,IT,Helpdesk Technician'
        $row = Import-ADFlowHireFile -Path $path -Config $config
        $row.Manager | Should -BeExactly ''
        $row.StartDate | Should -BeNullOrEmpty
        $row.Errors | Should -BeNullOrEmpty
    }

    It 'fails when a required column is missing' {
        $path = Write-TestHireFile -Header 'EmployeeId,FirstName,Department' -Rows 'E1,Ana,IT'
        { Import-ADFlowHireFile -Path $path -Config $config } | Should -Throw '*LastName, Title*'
    }

    It 'fails on a missing or empty file' {
        { Import-ADFlowHireFile -Path (Join-Path -Path $TestDrive -ChildPath 'none.csv') -Config $config } | Should -Throw '*not found*'
        $empty = Join-Path -Path $TestDrive -ChildPath 'empty.csv'
        [IO.File]::WriteAllText($empty, "`r`n")
        { Import-ADFlowHireFile -Path $empty -Config $config } | Should -Throw '*empty*'
    }

    It 'reports empty required fields' {
        $path = Write-TestHireFile -Rows 'E1,Ana,,IT,,,'
        $row = Import-ADFlowHireFile -Path $path -Config $config
        $row.Errors | Should -Contain 'LastName is empty'
        $row.Errors | Should -Contain 'Title is empty'
    }

    It 'reports repeated and malformed employee ids' {
        $path = Write-TestHireFile -Rows 'E1,Ana,Soto,IT,Helpdesk Technician,,', 'E1,Luis,Soto,IT,Helpdesk Technician,,', 'E 2,Eva,Mora,IT,Helpdesk Technician,,'
        $rows = @(Import-ADFlowHireFile -Path $path -Config $config)
        $rows[0].Errors | Should -BeNullOrEmpty
        $rows[1].Errors | Should -Match 'repeated \(first on row 2\)'
        $rows[2].Errors | Should -Match 'must be 1-16'
    }

    It 'reports an unknown department as an error and an unknown title as a warning' {
        $path = Write-TestHireFile -Rows 'E1,Ana,Soto,Legal,Lawyer,,'
        $row = Import-ADFlowHireFile -Path $path -Config $config
        $row.Errors | Should -Match "Department 'Legal'"
        $row.Warnings | Should -Match "Title 'Lawyer'"
    }

    It 'reports a start date that is not yyyy-MM-dd' {
        $path = Write-TestHireFile -Rows 'E1,Ana,Soto,IT,Helpdesk Technician,,01/12/2026'
        (Import-ADFlowHireFile -Path $path -Config $config).Errors | Should -Match 'yyyy-MM-dd'
    }

    It 'reports a name with no usable letters' {
        $path = Write-TestHireFile -Rows 'E1,***,Soto,IT,Helpdesk Technician,,'
        (Import-ADFlowHireFile -Path $path -Config $config).Errors | Should -Match 'no usable letters'
    }
}
