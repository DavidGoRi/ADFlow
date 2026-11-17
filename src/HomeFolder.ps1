#Requires -Version 5.1
<#
.SYNOPSIS
    Personal folders: where they are, their permissions and how they are archived.

.DESCRIPTION
    Each user has a folder <homeFolders.root>\<sAMAccountName>. When the
    person leaves, the folder is moved to
    <offboarding.archiveRoot>\<sAMAccountName>_<yyyyMMdd>, so their files are
    kept but no longer in the live share. The rollback moves it back.

    The callers decide about -DryRun and -WhatIf; these functions just act.
#>

function Test-ADFlowFolder {
    <#
    .SYNOPSIS
        $true when a folder exists and answers. An unreachable share is $false,
        not an error.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()] [string] $Path)
    if (-not $Path) { return $false }
    try { return [bool] (Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop) }
    catch { return $false }
}

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

# Well-known SIDs, the same on every Windows computer
$script:ADFlowSystemSid = 'S-1-5-18'
$script:ADFlowAdministratorsSid = 'S-1-5-32-544'

function Get-ADFlowHomeFolderAcl {
    <#
    .SYNOPSIS
        The permissions of a personal folder, as data.
    .DESCRIPTION
        Inheritance from the share is cut and only these entries are left:
          SYSTEM, Administrators and each admin   Full control
          the user                                Modify
        Modify lets the user work with their files but not change the
        permissions or take the folder over. All entries apply to the folder,
        its subfolders and its files.
    .PARAMETER User
        @{ Name = ...; Sid = ... }. Sid can be empty in a dry run, where the
        account does not exist yet.
    .PARAMETER Admins
        More entries with full control, as @{ Name = ...; Sid = ... }.
    .OUTPUTS
        Ordered dictionaries with Identity, Sid and Rights.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Collections.IDictionary] $User,
        [Collections.IDictionary[]] $Admins = @()
    )
    $entries = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $full = @(
        [ordered]@{ Name = 'SYSTEM'; Sid = $script:ADFlowSystemSid }
        [ordered]@{ Name = 'Administrators'; Sid = $script:ADFlowAdministratorsSid }
    ) + $Admins
    foreach ($admin in $full) {
        $key = if ($admin.Sid) { $admin.Sid } else { $admin.Name }
        if (-not $seen.Add($key)) { continue }
        $entries.Add([ordered]@{ Identity = $admin.Name; Sid = $admin.Sid; Rights = 'FullControl' })
    }
    $entries.Add([ordered]@{ Identity = $User.Name; Sid = $User.Sid; Rights = 'Modify' })
    return , $entries.ToArray()
}

function New-ADFlowHomeFolder {
    <#
    .SYNOPSIS
        Creates a personal folder with exactly the given permissions.
    .PARAMETER Acl
        Entries from Get-ADFlowHomeFolderAcl (or the same read back from JSON).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $Acl
    )
    if (Test-Path -LiteralPath $Path) { throw "The folder $Path already exists" }
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "The home folder root $parent does not exist" }

    $security = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
    # Protected: nothing inherited from the share
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags] 'ContainerInherit, ObjectInherit'
    foreach ($entry in $Acl) {
        $sid = Get-ADFlowActionValue $entry 'Sid'
        if (-not $sid) { throw "The permission for $(Get-ADFlowActionValue $entry 'Identity') has no SID" }
        $rule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @(
            (New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $sid),
            [Security.AccessControl.FileSystemRights] (Get-ADFlowActionValue $entry 'Rights'),
            $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Create personal folder')) {
        # Created with its permissions in one step, never open in between
        [void] [IO.Directory]::CreateDirectory($Path, $security)
    }
}

function Remove-ADFlowEmptyFolder {
    <#
    .SYNOPSIS
        Deletes a folder only when it is empty (rollback of an onboarding).
    .DESCRIPTION
        A folder that already holds files is kept: a rollback must never
        delete someone's data.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "The folder $Path does not exist" }
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count) { throw "The folder $Path is not empty and was kept" }
    if ($PSCmdlet.ShouldProcess($Path, 'Delete empty folder')) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
}

function Get-ADFlowFolderAclSummary {
    <#
    .SYNOPSIS
        The explicit permissions of a folder as "SID=Rights" texts, for checks.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $Path)
    $security = [IO.Directory]::GetAccessControl($Path, [Security.AccessControl.AccessControlSections]::Access)
    $rules = $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    return @($rules | ForEach-Object {
            # Windows adds Synchronize to Modify and FullControl
            $rights = [Security.AccessControl.FileSystemRights] ([int] $_.FileSystemRights -band (-bnot [int] [Security.AccessControl.FileSystemRights]::Synchronize))
            if ($_.FileSystemRights -eq [Security.AccessControl.FileSystemRights]::FullControl) { $rights = 'FullControl' }
            '{0}={1}{2}' -f $_.IdentityReference.Value, $rights, $(if ($_.IsInherited) { ' (inherited)' } else { '' })
        })
}

function Get-ADFlowHomeFolderAdmin {
    <#
    .SYNOPSIS
        Who gets full control of the personal folders besides SYSTEM and
        Administrators: homeFolders.adminGroups, plus the provider's own
        HomeFolderAdmins.
    .OUTPUTS
        Ordered dictionaries with Name and Sid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $Directory
    )
    $groupNames = if ($Config.homeFolders) { @($Config.homeFolders.adminGroups | Where-Object { $_ }) } else { @() }
    foreach ($name in $groupNames) {
        if ($Directory.TestGroup($name)) { [ordered]@{ Name = [string] $name; Sid = $Directory.GetGroupSid($name) } }
        else { Write-Warning "Home folder admin group $name does not exist in the directory and was left out" }
    }
    foreach ($sid in @($Directory.HomeFolderAdmins | Where-Object { $_ })) {
        [ordered]@{ Name = 'ADFlow operator'; Sid = [string] $sid }
    }
}
