#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $config = Get-ADFlowConfig -Path $configPath
    $config.homeFolders.root = ''
    $config.welcome = $null
    $logPath = Join-Path $TestDrive 'runs'
    function Read-Report($Folder) { return [IO.File]::ReadAllText((Join-Path $Folder 'report.html')) }
}

Describe 'Run reports' {
    BeforeAll {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
        $onboarding = @(Invoke-ADFlowOnboarding -CsvPath $demoCsvPath -Config $config -Directory $directory -LogPath $logPath)
        $html = Read-Report $onboarding[0].RunFolder
    }

    It 'writes report.html for every run' {
        Test-Path -Path (Join-Path $onboarding[0].RunFolder 'report.html') | Should -BeTrue
        $html | Should -Match '<title>ADFlow Onboarding '
        $html | Should -Match ([regex]::Escape($onboarding[0].RunId))
    }

    It 'has no placeholder left and no script' {
        $html | Should -Not -Match '\{\{'
        $html | Should -Not -Match '<script'
    }

    It 'lists every row with its status and the actions' {
        $html | Should -Match 'José Ángel Peña Muñoz'
        $html | Should -Match '<code>maximiliano.fernande</code>'
        $html | Should -Match '<span class="chip s-ok">Created</span>'
        $html | Should -Match '<span class="chip s-warn">Rejected</span>'
        $html | Should -Match 'Department &#39;Legal&#39; has no OU'
        $html | Should -Match 'Actions \(\d+\)'
        $html | Should -Match 'title="Can be undone"'
    }

    It 'shows OUs short, with the full DN as a tooltip' {
        $html | Should -Match '<span title="OU=Finance,OU=Staff,DC=corp,DC=example,DC=com">Finance / Staff</span>'
    }

    It 'escapes names typed by HR' {
        $csv = Write-TestHireFile -Rows 'E77,<script>alert(1)</script>,Soto,IT,Helpdesk Technician,,'
        $run = @(Invoke-ADFlowOnboarding -CsvPath $csv -Config $config -Directory $directory -LogPath $logPath)
        $text = Read-Report $run[0].RunFolder
        $text | Should -Not -Match '<script>alert'
        $text | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
    }

    It 'says when a run changed nothing' {
        $dry = @(Invoke-ADFlowOnboarding -CsvPath $demoCsvPath -Config $config -Directory $directory -LogPath $logPath -DryRun)
        Read-Report $dry[0].RunFolder | Should -Match 'Dry run: this is the plan. Nothing was changed.'
    }

    It 'marks the original run when it is rolled back, and reports the rollback' {
        $undo = @(Undo-ADFlowRun -RunFolder $onboarding[0].RunFolder -Directory $directory -LogPath $logPath)
        Read-Report $onboarding[0].RunFolder | Should -Match "rolled back by run <code>$($undo[0].RunId)</code>"
        $rollback = Read-Report $undo[0].RunFolder
        $rollback | Should -Match '<title>ADFlow Rollback '
        $rollback | Should -Match '<span class="chip s-ok">Reverted</span>'
    }

    It 'reports an offboarding with the groups removed' {
        $offboarding = @(Invoke-ADFlowOffboarding -CsvPath (Join-Path $repoRoot 'demo\leavers.csv') -Config $config -Directory $directory -LogPath $logPath)
        $text = Read-Report $offboarding[0].RunFolder
        $text | Should -Match 'Groups removed'
        $text | Should -Match '<span class="chip s-ok">Offboarded</span>'
        $text | Should -Match 'administrator is a protected account'
    }

    It 'can be written again for an old run' {
        $folder = $onboarding[0].RunFolder
        Remove-Item -Path (Join-Path $folder 'report.html')
        Export-ADFlowRunReport -RunFolder $folder | Should -Be (Join-Path $folder 'report.html')
        Test-Path -Path (Join-Path $folder 'report.html') | Should -BeTrue
    }
}
