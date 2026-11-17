#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $config = Get-ADFlowConfig -Path $configPath
}

Describe 'Expand-ADFlowTemplate' {
    It 'fills the placeholders, with or without spaces inside the braces' {
        Expand-ADFlowTemplate -Template 'Hi {{Name}}, {{ Place }}' -Values @{ Name = 'Íñigo'; Place = 'IT' } | Should -BeExactly 'Hi Íñigo, IT'
    }

    It 'escapes HTML special characters but keeps accents' {
        $html = Expand-ADFlowTemplate -Template '<p>{{Name}}</p>' -Values @{ Name = 'Zoë <b>"O''Connor"</b> & co' } -Html
        $html | Should -BeExactly '<p>Zoë &lt;b&gt;&quot;O&#39;Connor&quot;&lt;/b&gt; &amp; co</p>'
    }

    It 'fails on placeholders without a value and names them all' {
        { Expand-ADFlowTemplate -Template '{{A}} {{B}} {{A}}' -Values @{} } | Should -Throw '*unknown placeholder(s): A, B'
    }
}

Describe 'Welcome messages at onboarding' {
    BeforeAll {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $local = Get-ADFlowConfig -Path $configPath
        $local.homeFolders.root = ''
        $results = @(Invoke-ADFlowOnboarding -CsvPath $demoCsvPath -Config $local -Directory $directory -LogPath (Join-Path $TestDrive 'runs'))
        $welcomeFolder = Join-Path $results[0].RunFolder 'welcome'
        $jose = ConvertFrom-ADFlowWelcomeMessage -Path (Join-Path $welcomeFolder 'jose.pena.eml')
    }

    It 'writes one draft per new account and none for the rejected rows' {
        @(Get-ChildItem -Path $welcomeFolder -Filter '*.eml').Count | Should -Be 8
        (@($results | Where-Object EmployeeId -eq 'E1002')[0]).WelcomeMessage | Should -Be (Join-Path $welcomeFolder 'jose.pena.eml')
        @($results | Where-Object { $_.Status -eq 'Rejected' -and $_.WelcomeMessage }).Count | Should -Be 0
    }

    It 'is an unsent draft for the manager, with a copy to the helpdesk' {
        $jose.Headers['X-Unsent'] | Should -Be '1'
        $jose.Headers['To'] | Should -Be 'carlos.ruiz@corp.example.com'
        $jose.Headers['Cc'] | Should -Be 'it-helpdesk@corp.example.com'
        $jose.Headers['Content-Type'] | Should -Be 'text/html; charset=utf-8'
    }

    It 'keeps the accents of the subject and the body' {
        $jose.Subject | Should -BeExactly 'Welcome to Example Corp, José'
        $jose.Body | Should -Match 'José Ángel Peña Muñoz'
        $jose.Body | Should -Match 'Carlos Ruiz Navarro'
        $jose.Body | Should -Match '<strong>jose.pena</strong>'
        $jose.Body | Should -Match '2026-12-01'
    }

    It 'goes to the new account when there is no manager' {
        $pedro = ConvertFrom-ADFlowWelcomeMessage -Path (Join-Path $welcomeFolder 'pedro.delafuente.eml')
        $pedro.Headers['To'] | Should -Be 'pedro.delafuente@corp.example.com'
        $pedro.Body | Should -Match 'Hello team'
    }

    It 'never contains the temporary password' {
        $password = ConvertFrom-TestSecureString -Secure (@($results | Where-Object EmployeeId -eq 'E1002')[0]).Password
        [IO.File]::ReadAllText((Join-Path $welcomeFolder 'jose.pena.eml')) | Should -Not -Match ([regex]::Escape($password))
        $jose.Body | Should -Not -Match ([regex]::Escape($password))
    }

    It 'leaves no placeholder unfilled' {
        $jose.Body | Should -Not -Match '\{\{'
    }

    It 'writes drafts in a dry run, for review' {
        $dry = @(Invoke-ADFlowOnboarding -CsvPath $demoCsvPath -Config $local -Directory (Open-ADFlowMockDirectory -SeedPath $seedPath) -LogPath (Join-Path $TestDrive 'runs') -DryRun)
        @(Get-ChildItem -Path (Join-Path $dry[0].RunFolder 'welcome') -Filter '*.eml').Count | Should -Be 8
    }

    It 'turns a broken template into a warning, not a failure' {
        $broken = Join-Path $TestDrive 'broken.html'
        [IO.File]::WriteAllText($broken, '<p>{{Nickname}}</p>')
        $local.welcome.template = $broken
        $csv = Write-TestHireFile -Rows 'E9,Eva,Mora,IT,Helpdesk Technician,,'
        $result = @(Invoke-ADFlowOnboarding -CsvPath $csv -Config $local -Directory $directory -LogPath (Join-Path $TestDrive 'runs'))[0]
        $result.Status | Should -Be 'Created'
        $result.WelcomeMessage | Should -BeNullOrEmpty
        $result.Warnings -join ' ' | Should -Match 'Nickname'
    }
}
