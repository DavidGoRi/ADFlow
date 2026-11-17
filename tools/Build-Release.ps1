#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the release zip: ADFlow-<version>.zip plus its SHA-256 checksum.

.DESCRIPTION
    The zip contains what is needed to use ADFlow (the entry script, src,
    the sample settings and data, the lab script and guide, and the
    documentation), not the tests or screenshots. The version is read from
    src\Audit.ps1. Used by the Release workflow and can be run locally.

.EXAMPLE
    .\tools\Build-Release.ps1 -OutputPath .\dist
#>
[CmdletBinding()]
param([string] $OutputPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'dist'))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent

$match = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'src\Audit.ps1')), "ADFlowVersion = '(\d+\.\d+\.\d+)'")
if (-not $match.Success) { throw 'Version not found in src\Audit.ps1' }
$version = $match.Groups[1].Value

$OutputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)
$staging = Join-Path $OutputPath "ADFlow-$version"
if (Test-Path -Path $staging) { Remove-Item -Path $staging -Recurse -Force }
foreach ($folder in 'src', 'config', 'demo', 'tools', 'docs') {
    New-Item -ItemType Directory -Path (Join-Path $staging $folder) -Force | Out-Null
}

$files = @('ADFlow.ps1', 'LICENSE', 'README.md', 'README.es.md', 'CHANGELOG.md',
    'tools\New-ADFlowLab.ps1', 'docs\LAB.md', 'docs\LAB.es.md')
foreach ($file in $files) { Copy-Item -Path (Join-Path $root $file) -Destination (Join-Path $staging $file) }
foreach ($folder in 'src', 'config', 'demo') {
    Copy-Item -Path (Join-Path $root "$folder\*") -Destination (Join-Path $staging $folder)
}

$zip = Join-Path $OutputPath "ADFlow-$version.zip"
if (Test-Path -Path $zip) { Remove-Item -Path $zip -Force }
# Compress-Archive (and ZipFile.CreateFromDirectory, under the compatibility
# settings of powershell.exe) write "\" inside zip paths, which breaks other
# tools. Adding each entry with an explicit "/" name avoids it.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($item in Get-ChildItem -Path $staging -Recurse -File) {
        $entry = "ADFlow-$version/" + $item.FullName.Substring($staging.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $item.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}
finally { $archive.Dispose() }
Remove-Item -Path $staging -Recurse -Force

$hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zip.sha256", "$hash  ADFlow-$version.zip`n", (New-Object Text.UTF8Encoding($false)))

[pscustomobject]@{ Version = $version; Zip = $zip; Sha256 = $hash }
