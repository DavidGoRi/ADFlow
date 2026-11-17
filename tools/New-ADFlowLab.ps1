#Requires -Version 5.1
<#
.SYNOPSIS
    Prepares a test domain for ADFlow: OUs, groups, sample users and shares.

.DESCRIPTION
    Run it as a domain administrator on the domain controller of a LAB domain
    (see docs/LAB.md). It reads the same seed as the simulated directory
    (demo/directory.json) and creates what is missing:

      - the OUs, parents first;
      - the groups, as global security groups in OU=Groups (built-in groups
        such as Domain Users or Domain Admins are only filled in);
      - the sample users, each with a random password nobody knows;
      - the shares home$ and archive$ for personal folders (unless -SkipShares).

    It can be run again: anything that already exists is left alone.
    It refuses to run in a domain other than the one of the seed, so it can
    never fill a real domain with sample data by mistake.

.EXAMPLE
    .\tools\New-ADFlowLab.ps1 -WhatIf
    .\tools\New-ADFlowLab.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SeedPath = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'demo\directory.json'),
    [string] $SharesRoot = 'C:\Shares',
    [switch] $SkipShares,
    [string] $Server
)

$ErrorActionPreference = 'Stop'
foreach ($file in 'Password', 'ADDirectory') {
    . (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "src\$file.ps1")
}
if (-not (Get-Command -Name New-ADUser -ErrorAction SilentlyContinue)) { Import-Module -Name ActiveDirectory -Verbose:$false }

$connection = @{}
if ($Server) { $connection.Server = $Server }
$seed = [IO.File]::ReadAllText($SeedPath) | ConvertFrom-Json
$domain = Get-ADDomain @connection
$domainDn = [string] $domain.DistinguishedName

# Safety: the seed must belong to this domain
$seedDomains = @($seed.ous | ForEach-Object { ($_ -split ',' | Where-Object { $_ -like 'DC=*' }) -join ',' } | Sort-Object -Unique)
if ($seedDomains.Count -ne 1 -or $seedDomains[0] -ne $domainDn) {
    throw "The seed is for $($seedDomains -join ', ') but this domain is $domainDn. Use a lab domain created as in docs/LAB.md."
}

$created = [ordered]@{ OUs = 0; Groups = 0; Users = 0; Memberships = 0; Shares = 0 }

function Test-LabObject([scriptblock] $Lookup) {
    try { return $null -ne (& $Lookup) } catch { return $false }
}

# 1. OUs, parents first (fewer commas = higher up)
$groupsOu = "OU=Groups,$domainDn"
foreach ($ou in (@($seed.ous) + $groupsOu | Select-Object -Unique | Sort-Object -Property { ($_ -split ',').Count }, { $_ })) {
    if (Test-LabObject { Get-ADOrganizationalUnit -Identity $ou @connection }) { continue }
    $name, $parent = $ou -split ',', 2
    if ($PSCmdlet.ShouldProcess($ou, 'Create OU')) {
        New-ADOrganizationalUnit -Name ($name -replace '^OU=') -Path $parent -ProtectedFromAccidentalDeletion $false @connection
        $created.OUs++
    }
}

# 2. Groups
foreach ($group in $seed.groups) {
    $filter = "(sAMAccountName=$(ConvertTo-ADFlowLdapValue -Value $group.name))"
    if (Test-LabObject { Get-ADGroup -LDAPFilter $filter @connection }) { continue }
    if ($PSCmdlet.ShouldProcess($group.name, 'Create group')) {
        New-ADGroup -Name $group.name -SamAccountName $group.name -GroupScope Global -GroupCategory Security -Path $groupsOu @connection
        $created.Groups++
    }
}

# 3. Users (the built-in Administrator already exists)
foreach ($user in $seed.users) {
    $filter = "(sAMAccountName=$(ConvertTo-ADFlowLdapValue -Value $user.samAccountName))"
    if (Test-LabObject { Get-ADUser -LDAPFilter $filter @connection }) { continue }
    $parameters = @{
        Name              = $user.displayName
        SamAccountName    = $user.samAccountName
        UserPrincipalName = $user.userPrincipalName
        DisplayName       = $user.displayName
        Path              = $user.ou
        AccountPassword   = Get-ADFlowRandomPassword -Length 24
        Enabled           = [bool] $user.enabled
    }
    foreach ($pair in @(@('givenName', 'GivenName'), @('surname', 'Surname'), @('employeeId', 'EmployeeID'),
            @('department', 'Department'), @('title', 'Title'), @('description', 'Description'))) {
        if ($user.($pair[0])) { $parameters[$pair[1]] = [string] $user.($pair[0]) }
    }
    if ($PSCmdlet.ShouldProcess($user.samAccountName, 'Create user')) {
        New-ADUser @parameters @connection
        $created.Users++
    }
}

# 4. Memberships (Domain Users is every account's primary group already)
foreach ($group in $seed.groups) {
    if ($group.name -eq 'Domain Users') { continue }
    $groupFilter = "(sAMAccountName=$(ConvertTo-ADFlowLdapValue -Value $group.name))"
    $adGroup = @(Get-ADGroup -LDAPFilter $groupFilter @connection)[0]
    if (-not $adGroup) { continue }   # only in -WhatIf, when the group was not created
    $current = @(Get-ADGroupMember -Identity $adGroup @connection | ForEach-Object { $_.SamAccountName })
    foreach ($member in $group.members) {
        if ($current -contains $member) { continue }
        $memberFilter = "(sAMAccountName=$(ConvertTo-ADFlowLdapValue -Value $member))"
        $adUser = @(Get-ADUser -LDAPFilter $memberFilter @connection)[0]
        if (-not $adUser) { continue }
        if ($PSCmdlet.ShouldProcess("$member -> $($group.name)", 'Add group member')) {
            Add-ADGroupMember -Identity $adGroup -Members $adUser @connection
            $created.Memberships++
        }
    }
}

# 5. Shares for personal folders and their archive
if (-not $SkipShares) {
    # Names of built-in groups depend on the Windows language: use their SIDs
    $administrators = (New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value
    $authenticated = (New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-11').Translate([Security.Principal.NTAccount]).Value
    foreach ($share in @(@{ Name = 'home$'; Folder = 'Home' }, @{ Name = 'archive$'; Folder = 'Archive' })) {
        $path = Join-Path -Path $SharesRoot -ChildPath $share.Folder
        if (Get-SmbShare -Name $share.Name -ErrorAction SilentlyContinue) { continue }
        if ($PSCmdlet.ShouldProcess("\\$env:COMPUTERNAME\$($share.Name) ($path)", 'Create share')) {
            [void] [IO.Directory]::CreateDirectory($path)
            # NTFS decides who sees what; ADFlow sets the permissions of each personal folder
            New-SmbShare -Name $share.Name -Path $path -FullAccess $administrators -ChangeAccess $authenticated | Out-Null
            $created.Shares++
        }
    }
}

[pscustomobject] $created
