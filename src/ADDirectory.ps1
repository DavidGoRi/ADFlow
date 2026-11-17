#Requires -Version 5.1
<#
.SYNOPSIS
    The Active Directory provider: the same methods as the simulated
    directory (MockDirectory.ps1), on top of the RSAT ActiveDirectory module.

.DESCRIPTION
    Requirements on the computer that runs ADFlow:
      - the ActiveDirectory module (RSAT: Active Directory Domain Services and
        Lightweight Directory Services Tools, or a domain controller);
      - an account allowed to create, change, move and delete users in the
        OUs of the settings, and to manage the membership of their groups.

    Lookups use LDAP filters with every value escaped (RFC 4515), so a name
    typed by HR can never change the meaning of a query.

    The tests run this provider against a simulated ActiveDirectory module
    (tests/FakeActiveDirectory.psm1). See docs/LAB.md to try it against a
    real domain controller in Hyper-V.
#>

function ConvertTo-ADFlowLdapValue {
    <#
    .SYNOPSIS
        Escapes a value for an LDAP filter: \ * ( ) and NUL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
    $builder = New-Object -TypeName System.Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        switch ($character) {
            '\' { [void] $builder.Append('\5c') }
            '*' { [void] $builder.Append('\2a') }
            '(' { [void] $builder.Append('\28') }
            ')' { [void] $builder.Append('\29') }
            ([char] 0) { [void] $builder.Append('\00') }
            default { [void] $builder.Append($character) }
        }
    }
    return $builder.ToString()
}

function Get-ADFlowParentDn {
    <#
    .SYNOPSIS
        The container of an object: "CN=Peña\, Ana,OU=IT,DC=corp" -> "OU=IT,DC=corp".
        Escaped commas inside the name are respected.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $DistinguishedName)
    if ($DistinguishedName -match '^(?:[^,\\]|\\.)+,(.+)$') { return $Matches[1] }
    return ''
}

function ConvertFrom-ADFlowADUser {
    <#
    .SYNOPSIS
        Turns an ADUser into the user object that ADFlow uses everywhere.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $User)
    $sid = if ($User.SID -and $User.SID.Value) { [string] $User.SID.Value } else { [string] $User.SID }
    return [pscustomobject]@{
        samAccountName    = [string] $User.SamAccountName
        userPrincipalName = [string] $User.UserPrincipalName
        displayName       = [string] $User.DisplayName
        employeeId        = [string] $User.EmployeeID
        mail              = [string] $User.Mail
        description       = [string] $User.Description
        ou                = Get-ADFlowParentDn -DistinguishedName $User.DistinguishedName
        distinguishedName = [string] $User.DistinguishedName
        enabled           = [bool] $User.Enabled
        homeDirectory     = [string] $User.HomeDirectory
        homeDrive         = [string] $User.HomeDrive
        sid               = $sid
    }
}

function Open-ADFlowADDirectory {
    <#
    .SYNOPSIS
        Connects to Active Directory and returns the provider object.
    .PARAMETER Server
        A domain controller or domain name. By default, the one of the computer.
    .PARAMETER Credential
        An account with rights on the ADFlow OUs. By default, the current user.
        It is kept in memory only.
    #>
    [CmdletBinding()]
    param(
        [string] $Server,
        [pscredential] $Credential
    )

    if (-not (Get-Command -Name New-ADUser -ErrorAction SilentlyContinue)) {
        try { Import-Module -Name ActiveDirectory -ErrorAction Stop -Verbose:$false }
        catch {
            throw ('The ActiveDirectory module is not installed. On Windows 10/11 run, as administrator: ' +
                'Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0')
        }
    }

    $connection = @{}
    if ($Server) { $connection.Server = $Server }
    if ($Credential) { $connection.Credential = $Credential }
    try {
        $domain = Get-ADDomain @connection -ErrorAction Stop
    }
    catch {
        throw "Cannot reach Active Directory$(if ($Server) { " on $Server" }): $($_.Exception.Message)"
    }

    $directory = [pscustomobject]@{
        Name             = 'ActiveDirectory'
        Domain           = [string] $domain.DNSRoot
        Connection       = $connection
        # Admin groups of the settings already cover the operators in a domain
        HomeFolderAdmins = @()
        UserProperties   = @('EmployeeID', 'DisplayName', 'Description', 'Mail', 'UserPrincipalName', 'HomeDirectory', 'HomeDrive')
    }

    # Every method passes the connection (server, credential) to the cmdlets
    $directory | Add-Member -MemberType ScriptMethod -Name FindByLdap -Value {
        param([string] $Filter)
        $connection = $this.Connection
        $found = @(Get-ADUser -LDAPFilter $Filter -Properties $this.UserProperties @connection)
        if ($found.Count -eq 0) { return $null }
        return ConvertFrom-ADFlowADUser -User $found[0]
    }

    $directory | Add-Member -MemberType ScriptMethod -Name FindUser -Value {
        param([string] $SamAccountName)
        $value = ConvertTo-ADFlowLdapValue -Value $SamAccountName
        # A UPN prefix also counts as taken, as in the simulated directory
        return $this.FindByLdap("(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=$value)(userPrincipalName=$value@*)))")
    }

    $directory | Add-Member -MemberType ScriptMethod -Name FindUserByEmployeeId -Value {
        param([string] $EmployeeId)
        $value = ConvertTo-ADFlowLdapValue -Value $EmployeeId
        return $this.FindByLdap("(&(objectCategory=person)(objectClass=user)(employeeID=$value))")
    }

    $directory | Add-Member -MemberType ScriptMethod -Name GetADUser -Value {
        # The ADUser of an account; fails when it does not exist
        param([string] $SamAccountName, [string[]] $Properties = @())
        $query = @{}
        foreach ($key in $this.Connection.Keys) { $query[$key] = $this.Connection[$key] }
        if ($Properties.Count) { $query.Properties = $Properties }
        $value = ConvertTo-ADFlowLdapValue -Value $SamAccountName
        $found = @(Get-ADUser -LDAPFilter "(sAMAccountName=$value)" @query)
        if ($found.Count -eq 0) { throw "The user $SamAccountName does not exist" }
        return $found[0]
    }

    $directory | Add-Member -MemberType ScriptMethod -Name GetADGroup -Value {
        param([string] $Name)
        $connection = $this.Connection
        $value = ConvertTo-ADFlowLdapValue -Value $Name
        $found = @(Get-ADGroup -LDAPFilter "(sAMAccountName=$value)" @connection)
        if ($found.Count -eq 0) { throw "The group $Name does not exist" }
        return $found[0]
    }

    $directory | Add-Member -MemberType ScriptMethod -Name TestOu -Value {
        param([string] $DistinguishedName)
        $connection = $this.Connection
        try { return $null -ne (Get-ADOrganizationalUnit -Identity $DistinguishedName -ErrorAction Stop @connection) }
        catch { return $false }
    }

    $directory | Add-Member -MemberType ScriptMethod -Name TestGroup -Value {
        param([string] $Name)
        try { return $null -ne $this.GetADGroup($Name) }
        catch { return $false }
    }

    $directory | Add-Member -MemberType ScriptMethod -Name NewUser -Value {
        param([hashtable] $Spec)
        foreach ($key in 'SamAccountName', 'Ou', 'Password') {
            if (-not $Spec[$key]) { throw "NewUser needs $key" }
        }
        $connection = $this.Connection
        $display = if ($Spec.DisplayName) { [string] $Spec.DisplayName } else { [string] $Spec.SamAccountName }
        # The CN must be unique inside the OU: two "Ana Soto" get the user name added
        $cn = ConvertTo-ADFlowLdapValue -Value $display
        $sameName = @(Get-ADObject -LDAPFilter "(cn=$cn)" -SearchBase $Spec.Ou -SearchScope OneLevel @connection)
        $name = if ($sameName.Count) { "$display ($($Spec.SamAccountName))" } else { $display }

        $parameters = @{
            Name                  = $name
            SamAccountName        = $Spec.SamAccountName
            Path                  = $Spec.Ou
            AccountPassword       = $Spec.Password
            Enabled               = [bool] $Spec.Enabled
            ChangePasswordAtLogon = [bool] $Spec.ChangePasswordAtLogon
            DisplayName           = $display
            PassThru              = $true
            ErrorAction           = 'Stop'
        }
        # Empty values are left out: New-ADUser rejects some of them
        $optional = @{
            UserPrincipalName = 'UserPrincipalName'; GivenName = 'GivenName'; Surname = 'Surname'
            EmployeeId = 'EmployeeID'; Department = 'Department'; Title = 'Title'; Manager = 'Manager'
            Mail = 'EmailAddress'; Description = 'Description'; HomeDirectory = 'HomeDirectory'; HomeDrive = 'HomeDrive'
        }
        foreach ($key in $optional.Keys) {
            if ($Spec[$key]) { $parameters[$optional[$key]] = $Spec[$key] }
        }
        $created = New-ADUser @parameters @connection
        return ConvertFrom-ADFlowADUser -User $created
    }

    $directory | Add-Member -MemberType ScriptMethod -Name AddGroupMember -Value {
        param([string] $Group, [string] $SamAccountName)
        $connection = $this.Connection
        $user = $this.GetADUser($SamAccountName)
        Add-ADGroupMember -Identity $this.GetADGroup($Group) -Members $user -ErrorAction Stop @connection
    }

    $directory | Add-Member -MemberType ScriptMethod -Name RemoveGroupMember -Value {
        param([string] $Group, [string] $SamAccountName)
        $connection = $this.Connection
        $user = $this.GetADUser($SamAccountName)
        Remove-ADGroupMember -Identity $this.GetADGroup($Group) -Members $user -Confirm:$false -ErrorAction Stop @connection
    }

    $directory | Add-Member -MemberType ScriptMethod -Name GetGroupMembers -Value {
        param([string] $Group)
        $connection = $this.Connection
        $members = @(Get-ADGroupMember -Identity $this.GetADGroup($Group) -ErrorAction Stop @connection)
        return , @($members | ForEach-Object { [string] $_.SamAccountName } | Sort-Object)
    }

    $directory | Add-Member -MemberType ScriptMethod -Name GetUserGroups -Value {
        # Direct groups from memberOf; the primary group (Domain Users) is
        # added because it is not listed there
        param([string] $SamAccountName)
        $connection = $this.Connection
        $user = $this.GetADUser($SamAccountName, @('MemberOf', 'PrimaryGroup'))
        $names = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($dn in @($user.MemberOf) + @($user.PrimaryGroup)) {
            if (-not $dn) { continue }
            $names.Add([string] (Get-ADGroup -Identity $dn -ErrorAction Stop @connection).SamAccountName)
        }
        return , @($names | Sort-Object -Unique)
    }

    $directory | Add-Member -MemberType ScriptMethod -Name SetEnabled -Value {
        param([string] $SamAccountName, [bool] $Enabled)
        $connection = $this.Connection
        $user = $this.GetADUser($SamAccountName)
        if ($Enabled) { Enable-ADAccount -Identity $user -ErrorAction Stop @connection }
        else { Disable-ADAccount -Identity $user -ErrorAction Stop @connection }
    }

    $directory | Add-Member -MemberType ScriptMethod -Name SetDescription -Value {
        param([string] $SamAccountName, [string] $Description)
        $connection = $this.Connection
        $user = $this.GetADUser($SamAccountName)
        if ($Description) { Set-ADUser -Identity $user -Description $Description -ErrorAction Stop @connection }
        else { Set-ADUser -Identity $user -Clear 'description' -ErrorAction Stop @connection }
    }

    $directory | Add-Member -MemberType ScriptMethod -Name MoveUser -Value {
        param([string] $SamAccountName, [string] $TargetOu)
        $connection = $this.Connection
        $user = $this.GetADUser($SamAccountName)
        Move-ADObject -Identity $user.DistinguishedName -TargetPath $TargetOu -ErrorAction Stop @connection
    }

    $directory | Add-Member -MemberType ScriptMethod -Name RemoveUser -Value {
        param([string] $SamAccountName)
        $connection = $this.Connection
        $user = $this.GetADUser($SamAccountName)
        Remove-ADUser -Identity $user -Confirm:$false -ErrorAction Stop @connection
    }

    $directory | Add-Member -MemberType ScriptMethod -Name GetUserSid -Value {
        param([string] $SamAccountName)
        return [string] $this.GetADUser($SamAccountName).SID.Value
    }

    $directory | Add-Member -MemberType ScriptMethod -Name GetGroupSid -Value {
        param([string] $Name)
        return [string] $this.GetADGroup($Name).SID.Value
    }

    # Changes are written to Active Directory as they happen
    $directory | Add-Member -MemberType ScriptMethod -Name Save -Value { }

    return $directory
}
