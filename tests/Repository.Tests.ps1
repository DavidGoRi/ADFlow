#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeDiscovery {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $scripts = @(Get-ChildItem -Path $root -Recurse -Include '*.ps1', '*.psd1' -File |
            Where-Object { $_.FullName -notlike '*\output\*' } |
            ForEach-Object { @{ Name = $_.FullName.Substring($root.Length + 1); Path = $_.FullName } })
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
}

Describe 'Script files' {
    # Windows PowerShell 5.1 reads files without a BOM as ANSI and breaks accents
    It '<Name> is UTF-8 with BOM' -TestCases $scripts {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }

    It '<Name> parses without errors' -TestCases $scripts {
        $errors = $null
        [void] [Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $errors)
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Sample data' {
    It 'only uses the reserved example.com domain' {
        foreach ($file in Get-ChildItem -Path (Join-Path $repoRoot 'demo'), (Join-Path $repoRoot 'config') -File) {
            $text = [IO.File]::ReadAllText($file.FullName)
            foreach ($match in [regex]::Matches($text, '@([A-Za-z0-9.-]+)')) {
                $match.Groups[1].Value | Should -Be 'corp.example.com' -Because $file.Name
            }
            foreach ($match in [regex]::Matches($text, '(DC=[^,"]+,?)+')) {
                $match.Value.TrimEnd(',') | Should -Be 'DC=corp,DC=example,DC=com' -Because $file.Name
            }
        }
    }
}

Describe 'ADFlow.ps1' {
    It 'runs the demo as a dry run and leaves the simulated directory untouched' {
        $state = Join-Path -Path $TestDrive -ChildPath 'mock.json'
        $logs = Join-Path -Path $TestDrive -ChildPath 'runs'
        $results = & (Join-Path $repoRoot 'ADFlow.ps1') -Action Onboard -CsvPath $demoCsvPath -DryRun -PassThru `
            -MockStatePath $state -LogPath $logs -HomeRoot (Join-Path $TestDrive 'no-share') 6> $null
        @($results | Where-Object Status -eq 'Planned').Count | Should -Be 8
        Test-Path -Path $state | Should -BeFalse
        @(Get-ChildItem -Path $logs -Directory).Count | Should -Be 1
    }

    It 'creates the accounts and keeps them in the state file' {
        $state = Join-Path -Path $TestDrive -ChildPath 'mock-live.json'
        $logs = Join-Path -Path $TestDrive -ChildPath 'runs-live'
        $script = Join-Path $repoRoot 'ADFlow.ps1'
        $first = & $script -Action Onboard -CsvPath $demoCsvPath -PassThru -MockStatePath $state -LogPath $logs -HomeRoot (Join-Path $TestDrive 'no-share') 6> $null
        @($first | Where-Object Status -eq 'Created').Count | Should -Be 8
        $second = & $script -Action Onboard -CsvPath $demoCsvPath -PassThru -MockStatePath $state -LogPath $logs -HomeRoot (Join-Path $TestDrive 'no-share') 6> $null
        @($second | Where-Object Status -eq 'Created').Count | Should -Be 0
        $third = & $script -Action Onboard -CsvPath $demoCsvPath -PassThru -MockStatePath $state -LogPath $logs -HomeRoot (Join-Path $TestDrive 'no-share') -ResetMockDirectory 6> $null
        @($third | Where-Object Status -eq 'Created').Count | Should -Be 8
    }

    It 'offboards the demo leavers and undoes the run' {
        $common = @{
            MockStatePath = Join-Path -Path $TestDrive -ChildPath 'mock-leavers.json'
            LogPath       = Join-Path -Path $TestDrive -ChildPath 'runs-leavers'
            HomeRoot      = Join-Path -Path $TestDrive -ChildPath 'home'
            ArchiveRoot   = Join-Path -Path $TestDrive -ChildPath 'archive'
        }
        $script = Join-Path $repoRoot 'ADFlow.ps1'
        $leavers = Join-Path $repoRoot 'demo\leavers.csv'
        $done = & $script -Action Offboard -CsvPath $leavers -PassThru @common 6> $null
        @($done | Where-Object Status -eq 'Offboarded').Count | Should -Be 2
        $undo = & $script -Action Undo -RunId $done[0].RunId -PassThru @common 6> $null
        @($undo | Where-Object Status -eq 'Reverted').Count | Should -BeGreaterThan 0
        @($undo | Where-Object Status -ne 'Reverted').Count | Should -Be 0
        $state = [IO.File]::ReadAllText($common.MockStatePath) | ConvertFrom-Json
        @($state.users | Where-Object { $_.samAccountName -eq 'carlos.ruiz' })[0].enabled | Should -BeTrue
    }

    It 'writes the report of a run again' {
        $logs = Join-Path -Path $TestDrive -ChildPath 'runs-report'
        $script = Join-Path $repoRoot 'ADFlow.ps1'
        $run = & $script -Action Onboard -CsvPath $demoCsvPath -DryRun -PassThru -LogPath $logs -HomeRoot (Join-Path $TestDrive 'no-share') 6> $null
        $report = Join-Path $run[0].RunFolder 'report.html'
        Remove-Item -Path $report
        & $script -Action Report -RunId $run[0].RunId -LogPath $logs -PassThru 6> $null | Should -Be $report
        Test-Path -Path $report | Should -BeTrue
    }

    It 'asks for the parameters each action needs' {
        $script = Join-Path $repoRoot 'ADFlow.ps1'
        { & $script -Action Offboard 6> $null } | Should -Throw '*needs -CsvPath*'
        { & $script -Action Undo 6> $null } | Should -Throw '*needs -RunId*'
    }
}
