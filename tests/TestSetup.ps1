#Requires -Version 5.1
# Loaded by every test file in BeforeAll: the ADFlow functions and a few helpers.

$script:repoRoot = Split-Path -Path $PSScriptRoot -Parent
foreach ($file in 'Naming', 'Password', 'Config', 'HRFile', 'MockDirectory', 'Audit', 'Actions', 'HomeFolder',
    'Onboarding', 'Offboarding', 'Rollback') {
    . (Join-Path -Path $script:repoRoot -ChildPath "src\$file.ps1")
}
$script:configPath = Join-Path -Path $script:repoRoot -ChildPath 'config\adflow.json'
$script:seedPath = Join-Path -Path $script:repoRoot -ChildPath 'demo\directory.json'
$script:demoCsvPath = Join-Path -Path $script:repoRoot -ChildPath 'demo\new-hires.csv'

function ConvertFrom-TestSecureString {
    # Tests only: reads a SecureString back to check the generated passwords
    param([securestring] $Secure)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Write-TestHireFile {
    # Writes an HR file in TestDrive and returns its path
    param([string[]] $Rows, [string] $Name = 'hires.csv',
        [string] $Header = 'EmployeeId,FirstName,LastName,Department,Title,Manager,StartDate')
    $path = Join-Path -Path $TestDrive -ChildPath $Name
    [IO.File]::WriteAllLines($path, [string[]] (@($Header) + $Rows), (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
    return $path
}
