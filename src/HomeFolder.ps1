#Requires -Version 5.1
<#
.SYNOPSIS
    Personal folders: where they are and how they are archived.

.DESCRIPTION
    Each user has a folder <homeFolders.root>\<sAMAccountName>. When the
    person leaves, the folder is moved to
    <offboarding.archiveRoot>\<sAMAccountName>_<yyyyMMdd>, so their files are
    kept but no longer in the live share. The rollback moves it back.

    The callers decide about -DryRun and -WhatIf; these functions just act.
#>

function Get-ADFlowHomeFolderPath {
    <#
    .SYNOPSIS
        The personal folder of a user, or $null when no root is configured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()] [string] $Root,
        [Parameter(Mandatory)] [string] $SamAccountName
    )
    if (-not $Root) { return $null }
    return Join-Path -Path $Root -ChildPath $SamAccountName
}

function Get-ADFlowArchiveFolderPath {
    <#
    .SYNOPSIS
        A free archive path: <root>\<sam>_<yyyyMMdd>, then _2, _3...
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ArchiveRoot,
        [Parameter(Mandatory)] [string] $SamAccountName,
        [datetime] $Date = (Get-Date)
    )
    $base = Join-Path -Path $ArchiveRoot -ChildPath ('{0}_{1}' -f $SamAccountName, $Date.ToString('yyyyMMdd'))
    $candidate = $base
    $number = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = '{0}_{1}' -f $base, $number
        $number++
    }
    return $candidate
}

function Move-ADFlowFolder {
    <#
    .SYNOPSIS
        Moves a folder, also between different drives or shares.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Destination
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "The folder $Path does not exist" }
    if (Test-Path -LiteralPath $Destination) { throw "The destination $Destination already exists" }
    $parent = Split-Path -Path $Destination -Parent
    if ($parent) { [void] [IO.Directory]::CreateDirectory($parent) }

    $sameRoot = [IO.Path]::GetPathRoot($Path) -eq [IO.Path]::GetPathRoot($Destination)
    if ($sameRoot) {
        Move-Item -LiteralPath $Path -Destination $Destination -ErrorAction Stop -WhatIf:$false
    }
    else {
        # Move-Item cannot move folders across volumes in Windows PowerShell
        Copy-Item -LiteralPath $Path -Destination $Destination -Recurse -ErrorAction Stop -WhatIf:$false
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop -WhatIf:$false
    }
}
