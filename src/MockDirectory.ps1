#Requires -Version 5.1
<#
.SYNOPSIS
    A simulated directory: the provider used by the tests, the demo and any
    computer without Active Directory.

.DESCRIPTION
    ADFlow never calls the ActiveDirectory module directly. It talks to a
    "directory provider", an object with these methods:

      Name                              provider name, for the audit log
      FindUser(sam)                     the user, or $null
      FindUserByEmployeeId(id)          the user, or $null
      TestOu(dn) / TestGroup(name)      $true when it exists
      NewUser(spec)                     creates a user from a hashtable
      AddGroupMember(group, sam)        adds a user to a group
      GetGroupMembers(group)            the sAMAccountNames in a group
      Save()                            keeps the changes (no-op in AD)

    This file implements it in memory, loaded from and saved to a JSON file.
    The Active Directory provider (phase 4) implements the same methods with
    Get-ADUser, New-ADUser and Add-ADGroupMember, so the onboarding logic is
    the same in both and can be tested without a domain.

    The simulated directory never stores passwords: only that one was set.
#>

function Open-ADFlowMockDirectory {
    <#
    .SYNOPSIS
        Opens a simulated directory.
    .PARAMETER SeedPath
        JSON with the starting OUs, groups and users.
    .PARAMETER StatePath
        Where Save() writes the directory. When the file already exists it is
        loaded instead of the seed, so changes carry over between runs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SeedPath,
        [string] $StatePath
    )

    $source = $SeedPath
    if ($StatePath) {
        $StatePath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($StatePath)
        if (Test-Path -Path $StatePath -PathType Leaf) { $source = $StatePath }
    }
    if (-not (Test-Path -Path $source -PathType Leaf)) { throw "Simulated directory not found: $source" }
    $data = [IO.File]::ReadAllText($PSCmdlet.GetUnresolvedProviderPathFromPSPath($source)) | ConvertFrom-Json

    $ignoreCase = [StringComparer]::OrdinalIgnoreCase
    $ous = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList $ignoreCase
    foreach ($ou in @($data.ous)) { if ($ou) { [void] $ous.Add($ou) } }

    $groups = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' -ArgumentList $ignoreCase
    foreach ($group in @($data.groups)) {
        if (-not $group) { continue }
        $members = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($member in @($group.members)) { if ($member) { $members.Add($member) } }
        $groups[$group.name] = $members
    }

    $users = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList $ignoreCase
    foreach ($user in @($data.users)) { if ($user) { $users[$user.samAccountName] = $user } }

    $directory = [pscustomobject]@{
        Name      = 'Mock'
        StatePath = $StatePath
        Ous       = $ous
        Groups    = $groups
        Users     = $users
    }

    $directory | Add-Member -MemberType ScriptMethod -Name FindUser -Value {
        param([string] $SamAccountName)
        if ($this.Users.ContainsKey($SamAccountName)) { return $this.Users[$SamAccountName] }
        # A UPN prefix also counts as taken
        foreach ($user in $this.Users.Values) {
            if ($user.userPrincipalName -and ($user.userPrincipalName -split '@')[0] -eq $SamAccountName) { return $user }
        }
        return $null
    }

    $directory | Add-Member -MemberType ScriptMethod -Name FindUserByEmployeeId -Value {
        param([string] $EmployeeId)
        foreach ($user in $this.Users.Values) {
            if ($user.employeeId -and $user.employeeId -eq $EmployeeId) { return $user }
        }
        return $null
    }

    $directory | Add-Member -MemberType ScriptMethod -Name TestOu -Value {
        param([string] $DistinguishedName)
        return $this.Ous.Contains($DistinguishedName)
    }

    $directory | Add-Member -MemberType ScriptMethod -Name TestGroup -Value {
        param([string] $Name)
        return $this.Groups.ContainsKey($Name)
    }

    $directory | Add-Member -MemberType ScriptMethod -Name NewUser -Value {
        param([hashtable] $Spec)
        foreach ($key in 'SamAccountName', 'Ou', 'Password') {
            if (-not $Spec[$key]) { throw "NewUser needs $key" }
        }
        if ($null -ne $this.FindUser($Spec.SamAccountName)) { throw "The user $($Spec.SamAccountName) already exists" }
        if (-not $this.TestOu($Spec.Ou)) { throw "The OU $($Spec.Ou) does not exist" }
        if ($Spec.Manager -and $null -eq $this.FindUser($Spec.Manager)) { throw "The manager $($Spec.Manager) does not exist" }

        $user = [pscustomobject]@{
            samAccountName        = $Spec.SamAccountName
            userPrincipalName     = $Spec.UserPrincipalName
            givenName             = $Spec.GivenName
            surname               = $Spec.Surname
            displayName           = $Spec.DisplayName
            employeeId            = $Spec.EmployeeId
            department            = $Spec.Department
            title                 = $Spec.Title
            manager               = $Spec.Manager
            mail                  = $Spec.Mail
            ou                    = $Spec.Ou
            enabled               = [bool] $Spec.Enabled
            passwordSet           = $true
            changePasswordAtLogon = [bool] $Spec.ChangePasswordAtLogon
            created               = (Get-Date).ToString('s')
        }
        $this.Users[$user.samAccountName] = $user
        return $user
    }

    $directory | Add-Member -MemberType ScriptMethod -Name AddGroupMember -Value {
        param([string] $Group, [string] $SamAccountName)
        if (-not $this.Groups.ContainsKey($Group)) { throw "The group $Group does not exist" }
        if (-not $this.Users.ContainsKey($SamAccountName)) { throw "The user $SamAccountName does not exist" }
        $members = $this.Groups[$Group]
        if (-not ($members | Where-Object { $_ -eq $SamAccountName })) { $members.Add($SamAccountName) }
    }

    $directory | Add-Member -MemberType ScriptMethod -Name GetGroupMembers -Value {
        param([string] $Group)
        if (-not $this.Groups.ContainsKey($Group)) { throw "The group $Group does not exist" }
        return , $this.Groups[$Group].ToArray()
    }

    $directory | Add-Member -MemberType ScriptMethod -Name Save -Value {
        if (-not $this.StatePath) { return }
        $folder = Split-Path -Path $this.StatePath -Parent
        if ($folder) { [void] [IO.Directory]::CreateDirectory($folder) }
        $state = [ordered]@{
            ous    = @($this.Ous | Sort-Object)
            groups = @($this.Groups.Keys | Sort-Object | ForEach-Object {
                    [ordered]@{ name = $_; members = @($this.Groups[$_] | Sort-Object) }
                })
            users  = @($this.Users.Values | Sort-Object -Property samAccountName)
        }
        $json = ConvertTo-Json -InputObject $state -Depth 6
        [IO.File]::WriteAllText($this.StatePath, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    }

    return $directory
}
