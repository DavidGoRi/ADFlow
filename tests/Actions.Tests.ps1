#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
}

Describe 'Invoke-ADFlowAction' {
    BeforeEach {
        $directory = Open-ADFlowMockDirectory -SeedPath $seedPath
    }

    It 'runs actions written as hashtables' {
        Invoke-ADFlowAction -Directory $directory -Action @{ Action = 'SetEnabled'; SamAccountName = 'carlos.ruiz'; Enabled = $false }
        Invoke-ADFlowAction -Directory $directory -Action @{ Action = 'SetDescription'; SamAccountName = 'carlos.ruiz'; Description = 'Gone' }
        Invoke-ADFlowAction -Directory $directory -Action @{ Action = 'MoveUser'; SamAccountName = 'carlos.ruiz'; TargetOu = 'OU=Leavers,DC=corp,DC=example,DC=com' }
        Invoke-ADFlowAction -Directory $directory -Action @{ Action = 'RemoveGroupMember'; Group = 'GG-ERP-Users'; SamAccountName = 'carlos.ruiz' }
        $user = $directory.FindUser('carlos.ruiz')
        $user.enabled | Should -BeFalse
        $user.description | Should -Be 'Gone'
        $user.ou | Should -Be 'OU=Leavers,DC=corp,DC=example,DC=com'
        $directory.GetUserGroups('carlos.ruiz') | Should -Not -Contain 'GG-ERP-Users'
    }

    It 'runs actions read back from JSON' {
        $action = '{"Action":"AddGroupMember","Group":"GG-HR-Users","SamAccountName":"carlos.ruiz"}' | ConvertFrom-Json
        Invoke-ADFlowAction -Directory $directory -Action $action
        $directory.GetUserGroups('carlos.ruiz') | Should -Contain 'GG-HR-Users'
        $remove = '{"Action":"RemoveUser","SamAccountName":"carlos.ruiz"}' | ConvertFrom-Json
        Invoke-ADFlowAction -Directory $directory -Action $remove
        $directory.FindUser('carlos.ruiz') | Should -BeNullOrEmpty
        $directory.GetGroupMembers('GG-HR-Users') | Should -Not -Contain 'carlos.ruiz'
    }

    It 'moves folders' {
        $source = Join-Path -Path $TestDrive -ChildPath 'home\eva'
        [void] [IO.Directory]::CreateDirectory($source)
        $destination = Join-Path -Path $TestDrive -ChildPath 'archive\eva_20261130'
        Invoke-ADFlowAction -Directory $directory -Action @{ Action = 'MoveFolder'; Path = $source; Destination = $destination }
        Test-Path -Path $destination | Should -BeTrue
        Test-Path -Path $source | Should -BeFalse
    }

    It 'refuses unknown actions' {
        { Invoke-ADFlowAction -Directory $directory -Action @{ Action = 'FormatDisk' } } | Should -Throw "*Unknown action 'FormatDisk'*"
    }
}

Describe 'Action descriptions' {
    It 'describes <Name>' -TestCases @(
        @{ Name = 'SetEnabled'; Action = @{ Action = 'SetEnabled'; SamAccountName = 'a'; Enabled = $false }; Text = 'Disable account' }
        @{ Name = 'AddGroupMember'; Action = @{ Action = 'AddGroupMember'; SamAccountName = 'a'; Group = 'GG-X' }; Text = 'Add to group GG-X' }
        @{ Name = 'RemoveUser'; Action = @{ Action = 'RemoveUser'; SamAccountName = 'a' }; Text = 'Delete account' }
    ) {
        Get-ADFlowActionText -Action $Action | Should -Be $Text
        Get-ADFlowActionTarget -Action $Action | Should -Be 'a'
    }

    It 'uses the folder as the target of a folder move' {
        Get-ADFlowActionTarget -Action @{ Action = 'MoveFolder'; Path = 'C:\home\a'; Destination = 'C:\archive\a' } | Should -Be 'C:\home\a'
    }
}

Describe 'Home folders' {
    It 'builds the folder path, or nothing without a root' {
        Get-ADFlowHomeFolderPath -Root 'C:\home' -SamAccountName 'ana.soto' | Should -Be 'C:\home\ana.soto'
        Get-ADFlowHomeFolderPath -Root '' -SamAccountName 'ana.soto' | Should -BeNullOrEmpty
    }

    It 'picks a free archive folder name' {
        $root = Join-Path -Path $TestDrive -ChildPath 'archive'
        $date = [datetime] '2026-11-30'
        Get-ADFlowArchiveFolderPath -ArchiveRoot $root -SamAccountName 'ana' -Date $date | Should -Be (Join-Path $root 'ana_20261130')
        [void] [IO.Directory]::CreateDirectory((Join-Path $root 'ana_20261130'))
        Get-ADFlowArchiveFolderPath -ArchiveRoot $root -SamAccountName 'ana' -Date $date | Should -Be (Join-Path $root 'ana_20261130_2')
    }

    It 'refuses to move a missing folder or onto an existing one' {
        $source = Join-Path -Path $TestDrive -ChildPath 'src'
        $target = Join-Path -Path $TestDrive -ChildPath 'dst'
        { Move-ADFlowFolder -Path $source -Destination $target } | Should -Throw '*does not exist*'
        [void] [IO.Directory]::CreateDirectory($source)
        [void] [IO.Directory]::CreateDirectory($target)
        { Move-ADFlowFolder -Path $source -Destination $target } | Should -Throw '*already exists*'
    }

    It 'moves a folder with its content into a parent that does not exist yet' {
        $source = Join-Path -Path $TestDrive -ChildPath 'content'
        [void] [IO.Directory]::CreateDirectory((Join-Path $source 'sub'))
        [IO.File]::WriteAllText((Join-Path $source 'sub\file.txt'), 'x')
        $target = Join-Path -Path $TestDrive -ChildPath 'new\parent\content'
        Move-ADFlowFolder -Path $source -Destination $target
        Test-Path -Path (Join-Path $target 'sub\file.txt') | Should -BeTrue
    }
}
