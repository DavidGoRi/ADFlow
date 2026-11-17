#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Variables set in BeforeAll are used inside It blocks, which the analyzer cannot see
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $site = Join-Path $TestDrive 'site'
    $files = @(& (Join-Path $root 'tools\Build-Demo.ps1') -OutputPath $site)
    function Read-Page([string] $Name) { return [IO.File]::ReadAllText((Join-Path $site $Name)) }
}

Describe 'Live demo site' {
    It 'has the tour, the three reports, the welcome email and the HR files' {
        foreach ($name in 'index.html', 'onboarding.html', 'offboarding.html', 'rollback.html', 'welcome.html', 'data\new-hires.csv', 'data\leavers.csv') {
            Join-Path $site $name | Should -Exist
        }
        $files.Count | Should -Be 7
    }

    It 'only links to pages that exist' {
        foreach ($page in Get-ChildItem -Path $site -Filter '*.html') {
            foreach ($match in [regex]::Matches([IO.File]::ReadAllText($page.FullName), 'href="([^"#:]+)"')) {
                Join-Path $site $match.Groups[1].Value | Should -Exist -Because "$($page.Name) links to it"
            }
        }
    }

    It 'leaves no placeholder unfilled' {
        foreach ($page in Get-ChildItem -Path $site -Filter '*.html') {
            [IO.File]::ReadAllText($page.FullName) | Should -Not -Match '\{\{' -Because $page.Name
        }
    }

    It 'shows the real result of every step' {
        $index = Read-Page 'index.html'
        $index | Should -Match '<span class="ok">Created    E1001   maria.garcial'
        $index | Should -Match '<span class="warn">Rejected   E1008'
        $index | Should -Match '<span class="ok">Offboarded E0903   ana.garcial'
        $index | Should -Match 'administrator is a protected account'
        $index | Should -Match '<span class="ok">Reverted'
        $index | Should -Match '8 accounts created'
    }

    It 'is in English and Spanish' {
        $index = Read-Page 'index.html'
        $index | Should -Match '<span class="en">HR sends the new hires</span>'
        $index | Should -Match '<span class="es">RR. HH. envía las altas</span>'
        $index | Should -Match 'data-set-lang="es"'
    }

    It 'marks the offboarding report as rolled back' {
        Read-Page 'offboarding.html' | Should -Match 'This run was rolled back by run'
    }

    It 'replaces every local detail with fictitious ones' {
        foreach ($page in Get-ChildItem -Path $site -Recurse -File) {
            $text = [IO.File]::ReadAllText($page.FullName)
            $text | Should -Not -Match ([regex]::Escape($env:USERNAME)) -Because $page.Name
            $text | Should -Not -Match ([regex]::Escape($env:COMPUTERNAME)) -Because $page.Name
            $text | Should -Not -Match ([regex]::Escape([IO.Path]::GetTempPath())) -Because $page.Name
        }
        Read-Page 'onboarding.html' | Should -Match ([regex]::Escape('\\fs01.corp.example.com\home$\jose.pena'))
        Read-Page 'onboarding.html' | Should -Match 'CORP\\it.admin on ADM01'
    }
}
