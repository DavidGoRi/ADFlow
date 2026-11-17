#Requires -Version 5.1
# A module, not a script: its state ($script:) stays the same whoever calls the
# cmdlets (the provider, the lab script or the tests).
<#
.SYNOPSIS
    A small in-memory stand-in for the RSAT ActiveDirectory module, for tests.

.DESCRIPTION
    It defines the cmdlets that src/ADDirectory.ps1 and tools/New-ADFlowLab.ps1
    use (Get-ADUser, New-ADUser, Add-ADGroupMember, Move-ADObject...), with
    the same parameters and the behaviour ADFlow depends on:
      - users live in OUs and have a distinguished name, a SID and a
        primary group (Domain Users) that is not listed in memberOf;
      - the CN must be unique inside an OU;
      - LDAP filters are the ones ADFlow builds, with escaped values;
      - unknown identities throw, as the real cmdlets do.

    Every call is recorded, so tests can check the parameters (for example
    -Server or -Confirm:$false). Get-FakeADState returns the domain and the calls.

    It is not a general AD emulator: anything ADFlow does not use is missing.
#>

$script:FakeADDomain = 'DC=corp,DC=example,DC=com'
$script:FakeADDomainSid = 'S-1-5-21-4000-5000-6000'

function Initialize-FakeActiveDirectory {
    # Empty domain, or one loaded from a seed in the format of demo/directory.json
    param([string] $SeedPath)
    $ignoreCase = [StringComparer]::OrdinalIgnoreCase
    $script:FakeAD = @{
        Ous     = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList $ignoreCase
        Users   = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList $ignoreCase
        Groups  = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList $ignoreCase
        NextRid = 2000
    }
    $script:FakeADCalls = New-Object -TypeName 'System.Collections.Generic.List[object]'
    # Built-in containers and the primary group of every user
    [void] $script:FakeAD.Ous.Add("CN=Users,$script:FakeADDomain")
    Add-FakeADGroup -Name 'Domain Users' -Path "CN=Users,$script:FakeADDomain"
    if (-not $SeedPath) { return }

    $seed = [IO.File]::ReadAllText($SeedPath) | ConvertFrom-Json
    foreach ($ou in $seed.ous) { [void] $script:FakeAD.Ous.Add($ou) }
    foreach ($group in $seed.groups) {
        if (-not $script:FakeAD.Groups.ContainsKey($group.name)) { Add-FakeADGroup -Name $group.name -Path "CN=Users,$script:FakeADDomain" }
    }
    foreach ($user in $seed.users) {
        $added = Add-FakeADUser -Name $user.displayName -SamAccountName $user.samAccountName -Path $user.ou
        foreach ($property in 'userPrincipalName', 'employeeId', 'description', 'givenName', 'surname', 'department', 'title') {
            if ($user.$property) { $added[$property] = [string] $user.$property }
        }
        $added.Enabled = [bool] $user.enabled
        $added.DisplayName = $user.displayName
    }
    foreach ($group in $seed.groups) {
        if ($group.name -eq 'Domain Users') { continue }
        foreach ($member in $group.members) { [void] $script:FakeAD.Groups[$group.name].Members.Add($member) }
    }
}

function Get-FakeADNextSid {
    $script:FakeAD.NextRid++
    return New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList ('{0}-{1}' -f $script:FakeADDomainSid, $script:FakeAD.NextRid)
}

function Add-FakeADGroup {
    param([string] $Name, [string] $Path)
    $script:FakeAD.Groups[$Name] = @{
        Name              = $Name
        SamAccountName    = $Name
        DistinguishedName = "CN=$Name,$Path"
        SID               = Get-FakeADNextSid
        Members           = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    }
}

function Add-FakeADUser {
    param([string] $Name, [string] $SamAccountName, [string] $Path)
    $user = @{
        Name              = $Name
        SamAccountName    = $SamAccountName
        DistinguishedName = 'CN={0},{1}' -f ($Name -replace ',', '\,'), $Path
        SID               = Get-FakeADNextSid
        Enabled           = $true
        PrimaryGroup      = $script:FakeAD.Groups['Domain Users'].DistinguishedName
    }
    $script:FakeAD.Users[$SamAccountName] = $user
    return $user
}

function Add-FakeADCall {
    param([string] $Command, [hashtable] $Parameters)
    $script:FakeADCalls.Add([pscustomobject]@{ Command = $Command; Parameters = $Parameters })
}

function ConvertFrom-FakeLdapValue {
    param([string] $Value)
    return $Value.Replace('\28', '(').Replace('\29', ')').Replace('\2a', '*').Replace('\00', [string] [char] 0).Replace('\5c', '\')
}

function Get-FakeADUserView {
    # What Get-ADUser returns: a fresh object with memberOf worked out
    param($User)
    $memberOf = @($script:FakeAD.Groups.Values | Where-Object { $_.Members.Contains($User.SamAccountName) } |
            ForEach-Object { $_.DistinguishedName })
    $view = [ordered]@{}
    foreach ($key in $User.Keys) { $view[$key] = $User[$key] }
    $view.MemberOf = $memberOf
    $view.Mail = $User.EmailAddress
    $view.ObjectClass = 'user'
    return [pscustomobject] $view
}

function Resolve-FakeADUser {
    param($Identity)
    $key = if ($Identity -is [string]) { $Identity } else { [string] $Identity.DistinguishedName }
    foreach ($user in $script:FakeAD.Users.Values) {
        if ($user.DistinguishedName -eq $key -or $user.SamAccountName -eq $key) { return $user }
    }
    throw "Cannot find an object with identity: '$key' under: '$script:FakeADDomain'."
}

function Resolve-FakeADGroup {
    param($Identity)
    $key = if ($Identity -is [string]) { $Identity } else { [string] $Identity.DistinguishedName }
    foreach ($group in $script:FakeAD.Groups.Values) {
        if ($group.DistinguishedName -eq $key -or $group.SamAccountName -eq $key) { return $group }
    }
    throw "Cannot find an object with identity: '$key' under: '$script:FakeADDomain'."
}

function Get-FakeADGroupView {
    param($Group)
    return [pscustomobject]@{
        Name = $Group.Name; SamAccountName = $Group.SamAccountName
        DistinguishedName = $Group.DistinguishedName; SID = $Group.SID; ObjectClass = 'group'
    }
}

# ---------------------------------------------------------------------------
# The cmdlets
# ---------------------------------------------------------------------------

function Get-ADDomain {
    [CmdletBinding()]
    param([string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Get-ADDomain' $PSBoundParameters
    return [pscustomobject]@{ DNSRoot = 'corp.example.com'; DistinguishedName = $script:FakeADDomain; DomainSID = $script:FakeADDomainSid }
}

function Get-ADUser {
    [CmdletBinding()]
    param($Identity, [string] $LDAPFilter, [string[]] $Properties, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Get-ADUser' $PSBoundParameters
    if ($Identity) { return Get-FakeADUserView (Resolve-FakeADUser $Identity) }
    $sam = if ($LDAPFilter -match '\(sAMAccountName=([^)]*)\)') { ConvertFrom-FakeLdapValue $Matches[1] }
    $upnPrefix = if ($LDAPFilter -match '\(userPrincipalName=([^)]*)@\*\)') { ConvertFrom-FakeLdapValue $Matches[1] }
    $employeeId = if ($LDAPFilter -match '\(employeeID=([^)]*)\)') { ConvertFrom-FakeLdapValue $Matches[1] }
    foreach ($user in $script:FakeAD.Users.Values) {
        $hit = ($sam -and $user.SamAccountName -eq $sam) -or
        ($upnPrefix -and $user.UserPrincipalName -and ($user.UserPrincipalName -split '@')[0] -eq $upnPrefix) -or
        ($employeeId -and $user.EmployeeID -eq $employeeId)
        if ($hit) { Get-FakeADUserView $user }
    }
}

function Get-ADGroup {
    [CmdletBinding()]
    param($Identity, [string] $LDAPFilter, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Get-ADGroup' $PSBoundParameters
    if ($Identity) { return Get-FakeADGroupView (Resolve-FakeADGroup $Identity) }
    if ($LDAPFilter -match '\(sAMAccountName=([^)]*)\)') {
        $name = ConvertFrom-FakeLdapValue $Matches[1]
        if ($script:FakeAD.Groups.ContainsKey($name)) { return Get-FakeADGroupView $script:FakeAD.Groups[$name] }
    }
}

function Get-ADObject {
    [CmdletBinding()]
    param([string] $LDAPFilter, [string] $SearchBase, [string] $SearchScope, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Get-ADObject' $PSBoundParameters
    if ($LDAPFilter -match '\(cn=([^)]*)\)') {
        $cn = ConvertFrom-FakeLdapValue $Matches[1]
        foreach ($user in $script:FakeAD.Users.Values) {
            if ($user.Name -eq $cn -and $user.DistinguishedName.EndsWith(",$SearchBase")) { [pscustomobject]@{ Name = $user.Name } }
        }
    }
}

function Get-ADOrganizationalUnit {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Identity, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Get-ADOrganizationalUnit' $PSBoundParameters
    if (-not $script:FakeAD.Ous.Contains($Identity)) { throw "Directory object not found: $Identity" }
    return [pscustomobject]@{ DistinguishedName = $Identity }
}

function New-ADOrganizationalUnit {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Path,
        [bool] $ProtectedFromAccidentalDeletion, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'New-ADOrganizationalUnit' $PSBoundParameters
    if (-not ($script:FakeAD.Ous.Contains($Path) -or $Path -eq $script:FakeADDomain)) { throw "The parent $Path does not exist" }
    if ($PSCmdlet.ShouldProcess($Name)) { [void] $script:FakeAD.Ous.Add("OU=$Name,$Path") }
}

function New-ADGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Name, [string] $SamAccountName, [string] $GroupScope, [string] $GroupCategory,
        [string] $Path, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'New-ADGroup' $PSBoundParameters
    if ($PSCmdlet.ShouldProcess($Name)) { Add-FakeADGroup -Name $Name -Path $Path }
}

function New-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Name, [string] $SamAccountName, [string] $Path, [securestring] $AccountPassword,
        [bool] $Enabled, [bool] $ChangePasswordAtLogon, [string] $DisplayName, [switch] $PassThru,
        [string] $UserPrincipalName, [string] $GivenName, [string] $Surname, [string] $EmployeeID, [string] $Department,
        [string] $Title, $Manager, [string] $EmailAddress, [string] $Description, [string] $HomeDirectory, [string] $HomeDrive,
        [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'New-ADUser' $PSBoundParameters
    if ($script:FakeAD.Users.ContainsKey($SamAccountName)) { throw 'The specified account already exists' }
    if (-not $script:FakeAD.Ous.Contains($Path)) { throw "Directory object not found: $Path" }
    foreach ($user in $script:FakeAD.Users.Values) {
        if ($user.Name -eq $Name -and $user.DistinguishedName.EndsWith(",$Path")) { throw 'The name provided is already in use' }
    }
    if ($Enabled -and -not $AccountPassword) { throw 'An enabled account needs a password' }
    $managerDn = if ($Manager) { (Resolve-FakeADUser $Manager).DistinguishedName } else { $null }
    if (-not $PSCmdlet.ShouldProcess($Name)) { return }
    $user = Add-FakeADUser -Name $Name -SamAccountName $SamAccountName -Path $Path
    $user.Enabled = $Enabled
    $user.ChangePasswordAtLogon = $ChangePasswordAtLogon
    $user.Manager = $managerDn
    foreach ($property in 'DisplayName', 'UserPrincipalName', 'GivenName', 'Surname', 'EmployeeID', 'Department', 'Title',
        'EmailAddress', 'Description', 'HomeDirectory', 'HomeDrive') {
        if ($PSBoundParameters.ContainsKey($property)) { $user[$property] = $PSBoundParameters[$property] }
    }
    if ($PassThru) { return Get-FakeADUserView $user }
}

function Add-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Identity, [Parameter(Mandatory)] $Members, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Add-ADGroupMember' $PSBoundParameters
    $group = Resolve-FakeADGroup $Identity
    foreach ($member in @($Members)) {
        $sam = (Resolve-FakeADUser $member).SamAccountName
        if ($PSCmdlet.ShouldProcess($sam)) { [void] $group.Members.Add($sam) }
    }
}

function Remove-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)] $Identity, [Parameter(Mandatory)] $Members, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Remove-ADGroupMember' $PSBoundParameters
    $group = Resolve-FakeADGroup $Identity
    foreach ($member in @($Members)) {
        $sam = (Resolve-FakeADUser $member).SamAccountName
        if ($group.DistinguishedName -eq (Resolve-FakeADUser $member).PrimaryGroup) { throw 'The user cannot be removed from a group because the group is currently the user''s primary group' }
        if ($PSCmdlet.ShouldProcess($sam)) { [void] $group.Members.Remove($sam) }
    }
}

function Get-ADGroupMember {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Identity, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Get-ADGroupMember' $PSBoundParameters
    $group = Resolve-FakeADGroup $Identity
    foreach ($user in $script:FakeAD.Users.Values) {
        if ($group.Members.Contains($user.SamAccountName) -or $user.PrimaryGroup -eq $group.DistinguishedName) {
            [pscustomobject]@{ SamAccountName = $user.SamAccountName; DistinguishedName = $user.DistinguishedName; ObjectClass = 'user' }
        }
    }
}

function Enable-ADAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Identity, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Enable-ADAccount' $PSBoundParameters
    $user = Resolve-FakeADUser $Identity
    if ($PSCmdlet.ShouldProcess($user.SamAccountName)) { $user.Enabled = $true }
}

function Disable-ADAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Identity, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Disable-ADAccount' $PSBoundParameters
    $user = Resolve-FakeADUser $Identity
    if ($PSCmdlet.ShouldProcess($user.SamAccountName)) { $user.Enabled = $false }
}

function Set-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Identity, [string] $Description, [string[]] $Clear, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Set-ADUser' $PSBoundParameters
    $user = Resolve-FakeADUser $Identity
    if (-not $PSCmdlet.ShouldProcess($user.SamAccountName)) { return }
    if ($PSBoundParameters.ContainsKey('Description')) { $user.Description = $Description }
    if ($Clear -contains 'description') { $user.Remove('Description') }
}

function Move-ADObject {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Identity, [Parameter(Mandatory)] [string] $TargetPath, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Move-ADObject' $PSBoundParameters
    $user = Resolve-FakeADUser $Identity
    if (-not $script:FakeAD.Ous.Contains($TargetPath)) { throw "Directory object not found: $TargetPath" }
    if ($PSCmdlet.ShouldProcess($user.SamAccountName)) {
        $user.DistinguishedName = 'CN={0},{1}' -f ($user.Name -replace ',', '\,'), $TargetPath
    }
}

function Remove-ADUser {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)] $Identity, [string] $Server, [pscredential] $Credential)
    Add-FakeADCall 'Remove-ADUser' $PSBoundParameters
    $user = Resolve-FakeADUser $Identity
    if (-not $PSCmdlet.ShouldProcess($user.SamAccountName)) { return }
    foreach ($group in $script:FakeAD.Groups.Values) { [void] $group.Members.Remove($user.SamAccountName) }
    [void] $script:FakeAD.Users.Remove($user.SamAccountName)
}

function Get-FakeADState {
    # The simulated domain and the recorded calls, for assertions
    return @{
        Ous    = $script:FakeAD.Ous
        Users  = $script:FakeAD.Users
        Groups = $script:FakeAD.Groups
        Calls  = $script:FakeADCalls
    }
}

Export-ModuleMember -Function @(
    'Initialize-FakeActiveDirectory', 'Get-FakeADState'
    'Get-ADDomain', 'Get-ADUser', 'Get-ADGroup', 'Get-ADObject', 'Get-ADOrganizationalUnit', 'New-ADOrganizationalUnit',
    'New-ADGroup', 'New-ADUser', 'Add-ADGroupMember', 'Remove-ADGroupMember', 'Get-ADGroupMember', 'Enable-ADAccount',
    'Disable-ADAccount', 'Set-ADUser', 'Move-ADObject', 'Remove-ADUser'
)
