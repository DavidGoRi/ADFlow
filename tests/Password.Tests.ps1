#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
}

Describe 'Get-ADFlowRandomIndex' {
    It 'stays within 0 and Count - 1' {
        $values = 1..500 | ForEach-Object { Get-ADFlowRandomIndex -Count 7 }
        ($values | Measure-Object -Minimum -Maximum).Minimum | Should -BeGreaterOrEqual 0
        ($values | Measure-Object -Minimum -Maximum).Maximum | Should -BeLessOrEqual 6
        @($values | Sort-Object -Unique).Count | Should -Be 7
    }

    It 'returns 0 when there is only one choice' {
        Get-ADFlowRandomIndex -Count 1 | Should -Be 0
    }
}

Describe 'Get-ADFlowRandomPassword' {
    It 'returns a read-only SecureString' {
        $secure = Get-ADFlowRandomPassword
        $secure | Should -BeOfType [securestring]
        $secure.IsReadOnly() | Should -BeTrue
        $secure.Length | Should -Be 16
    }

    It 'honours the length' {
        (Get-ADFlowRandomPassword -Length 24).Length | Should -Be 24
    }

    It 'refuses passwords shorter than 12 characters' {
        { Get-ADFlowRandomPassword -Length 8 } | Should -Throw
    }

    It 'always has upper case, lower case, a digit and a symbol' {
        foreach ($i in 1..50) {
            $plain = ConvertFrom-TestSecureString -Secure (Get-ADFlowRandomPassword -Length 12)
            $plain | Should -MatchExactly '[A-Z]'
            $plain | Should -MatchExactly '[a-z]'
            $plain | Should -Match '[0-9]'
            $plain | Should -Match '[^A-Za-z0-9]'
        }
    }

    It 'leaves out characters that are easy to confuse' {
        $all = -join (1..30 | ForEach-Object { ConvertFrom-TestSecureString -Secure (Get-ADFlowRandomPassword -Length 32) })
        $all | Should -Not -MatchExactly '[O0Il1]'
    }

    It 'does not repeat passwords' {
        $passwords = 1..100 | ForEach-Object { ConvertFrom-TestSecureString -Secure (Get-ADFlowRandomPassword) }
        @($passwords | Sort-Object -Unique).Count | Should -Be 100
    }
}
