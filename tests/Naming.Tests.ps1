#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Variables set in BeforeAll are used inside It blocks, which the analyzer cannot see
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
}

Describe 'ConvertTo-ADFlowAscii' {
    It 'folds <Text> to <Expected>' -TestCases @(
        @{ Text = 'María José'; Expected = 'maria jose' }
        @{ Text = 'ÍÑIGO PEÑA'; Expected = 'inigo pena' }
        @{ Text = 'Zoë Çelik'; Expected = 'zoe celik' }
        @{ Text = 'Jürgen Groß'; Expected = 'jurgen gross' }
        @{ Text = 'Łukasz Øster'; Expected = 'lukasz oster' }
        @{ Text = 'Nuria Lloret i Vidal'; Expected = 'nuria lloret i vidal' }
    ) {
        ConvertTo-ADFlowAscii -Text $Text | Should -BeExactly $Expected
    }
}

Describe 'Split-ADFlowPersonName' {
    It 'keeps surname particles with their surname' {
        $name = Split-ADFlowPersonName -FirstName 'Pedro' -LastName 'de la Fuente Ruiz'
        $name.Surnames | Should -Be @('delafuente', 'ruiz')
    }

    It 'joins hyphenated and apostrophe surnames' {
        (Split-ADFlowPersonName -FirstName 'Íñigo' -LastName 'Martínez-Aragón').Surnames | Should -Be @('martinezaragon')
        (Split-ADFlowPersonName -FirstName 'Zoë' -LastName "O'Connor").Surnames | Should -Be @('oconnor')
    }

    It 'drops the connector between two surnames' {
        (Split-ADFlowPersonName -FirstName 'José' -LastName 'Ortega y Gasset').Surnames | Should -Be @('ortega', 'gasset')
    }

    It 'returns every given name' {
        (Split-ADFlowPersonName -FirstName 'María  José' -LastName 'García').Given | Should -Be @('maria', 'jose')
    }

    It 'rejects a name with no letters' {
        { Split-ADFlowPersonName -FirstName '---' -LastName 'García' } | Should -Throw '*first name*'
        { Split-ADFlowPersonName -FirstName 'Ana' -LastName ' ' } | Should -Throw '*last name*'
    }
}

Describe 'Get-ADFlowSamAccountName' {
    It 'uses the first given name and the first surname' {
        Get-ADFlowSamAccountName -FirstName 'María José' -LastName 'García López' | Should -BeExactly 'maria.garcia'
    }

    It 'adds the initial of the second surname when the name is taken' {
        $taken = { param($name) $name -eq 'maria.garcia' }
        Get-ADFlowSamAccountName -FirstName 'María José' -LastName 'García López' -Exists $taken | Should -BeExactly 'maria.garcial'
    }

    It 'adds a number when the other forms are taken' {
        $taken = { param($name) $name -in 'ana.garcia', 'ana.garcial', 'ana.garcia2' }
        Get-ADFlowSamAccountName -FirstName 'Ana' -LastName 'García López' -Exists $taken | Should -BeExactly 'ana.garcia3'
    }

    It 'goes straight to numbers when there is one surname' {
        $taken = { param($name) $name -eq 'luis.soto' }
        Get-ADFlowSamAccountName -FirstName 'Luis' -LastName 'Soto' -Exists $taken | Should -BeExactly 'luis.soto2'
    }

    It 'compares taken names without regard to case' {
        $existing = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
        [void] $existing.Add('LUIS.SOTO')
        $taken = { param($name) $existing.Contains($name) }.GetNewClosure()
        Get-ADFlowSamAccountName -FirstName 'Luis' -LastName 'Soto' -Exists $taken | Should -BeExactly 'luis.soto2'
    }

    It 'never goes over the 20 characters of sAMAccountName' {
        $sam = Get-ADFlowSamAccountName -FirstName 'Maximiliano' -LastName 'Fernández-Villaverde'
        $sam | Should -BeExactly 'maximiliano.fernande'
        $sam.Length | Should -Be 20
    }

    It 'shortens the base, not the suffix, of a long taken name' {
        $taken = { param($name) $name -in 'maximiliano.fernande', 'maximiliano.fernandg' }
        $sam = Get-ADFlowSamAccountName -FirstName 'Maximiliano' -LastName 'Fernández-Villaverde García' -Exists $taken
        $sam | Should -BeExactly 'maximiliano.fernand2'
    }

    It 'never ends the base in a dot when shortening' {
        $sam = Get-ADFlowSamAccountName -FirstName 'Bartholomew' -LastName 'Long' -MaxLength 12 -Exists { param($name) $name -eq 'bartholomew.' -or $name -eq 'bartholomew' }
        # 'bartholomew.long' cut to 12 is 'bartholomew.', which loses its dot
        $sam | Should -BeExactly 'bartholomew2'
    }

    It 'only uses lower case letters, digits and one dot' {
        $sam = Get-ADFlowSamAccountName -FirstName 'Zoë' -LastName "O'Connor"
        $sam | Should -BeExactly 'zoe.oconnor'
        $sam | Should -Match '^[a-z0-9]+\.[a-z0-9]+$'
    }

    It 'fails when every candidate is taken' {
        { Get-ADFlowSamAccountName -FirstName 'Ana' -LastName 'Soto' -Exists { $true } -MaxNumber 3 } | Should -Throw '*No free user name*'
    }
}
