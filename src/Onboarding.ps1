#Requires -Version 5.1
<#
.SYNOPSIS
    Onboarding: creates the accounts of the HR file of new hires.

.DESCRIPTION
    For each valid row:
      1. skips the person if the directory already has their EmployeeId,
         so running the same file twice does not create duplicates;
      2. picks a unique user name (Get-ADFlowSamAccountName);
      3. finds the OU of the department and the groups of the job title;
      4. creates the enabled account with a temporary password that must be
         changed at the first logon;
      5. adds it to its groups.

    Modes:
      -DryRun   works out every name, OU and group and logs them as Planned,
                without touching the directory. Use it to review a file.
      -WhatIf   standard PowerShell: each change is announced and skipped.
      (none)    makes the changes.

    One row that fails does not stop the others.
#>

function Invoke-ADFlowOnboarding {
    <#
    .SYNOPSIS
        Processes an HR file of new hires and returns one result per row.
    .OUTPUTS
        Objects with Row, EmployeeId, DisplayName, SamAccountName,
        UserPrincipalName, Ou, Groups, Status, Message, Warnings and Password
        (a SecureString, only for accounts created in this run). Status is
        Created, Planned, WhatIf, Skipped, Rejected or Failed.
        The run folder and summary are in the RunFolder and RunId of each one.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $CsvPath,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $Directory,
        [Parameter(Mandatory)] [string] $LogPath,
        [switch] $DryRun
    )

    $mode = if ($DryRun) { 'DryRun' } elseif ($WhatIfPreference) { 'WhatIf' } else { 'Live' }
    $records = @(Import-ADFlowHireFile -Path $CsvPath -Config $Config)
    $run = Initialize-ADFlowRun -LogPath $LogPath -Operation Onboarding -Mode $mode -Provider $Directory.Name -Source $CsvPath

    # Names given in this run, so two new hires never get the same one,
    # even in a dry run where nothing is created
    $reserved = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $results = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $changed = $false
    $folderAdmins = @(Get-ADFlowHomeFolderAdmin -Config $Config -Directory $Directory)
    # Checked once: an unreachable share can take seconds to answer
    $homeRoot = if ($Config.homeFolders) { [string] $Config.homeFolders.root } else { '' }
    $homeRootIssue = $null
    if ($homeRoot -and -not (Test-ADFlowFolder -Path $homeRoot)) {
        $homeRootIssue = "Home folder root $homeRoot is not reachable: no personal folder was created"
    }

    foreach ($record in $records) {
        $result = Invoke-ADFlowHireRecord -Record $record -Config $Config -Directory $Directory -Run $run `
            -Reserved $reserved -Mode $mode -FolderAdmins $folderAdmins -HomeRoot $homeRoot -HomeRootIssue $homeRootIssue
        if ($result.Status -eq 'Created') { $changed = $true }
        if ($Config.welcome -and $result.Status -in 'Created', 'Planned') {
            try {
                $welcome = Export-ADFlowWelcomeMessage -Result $result -Record $record -Config $Config -Directory $Directory `
                    -Folder (Join-Path -Path $run.Folder -ChildPath 'welcome')
                $result.WelcomeMessage = $welcome
            }
            catch {
                $result.Warnings = @($result.Warnings) + "Welcome message not written: $(Get-ADFlowErrorMessage $_)"
            }
        }
        $results.Add($result)
    }

    if ($changed) { $Directory.Save() }
    [void] (Complete-ADFlowRun -Run $run -Results $results.ToArray())
    foreach ($result in $results) {
        $result | Add-Member -NotePropertyName RunId -NotePropertyValue $run.RunId
        $result | Add-Member -NotePropertyName RunFolder -NotePropertyValue $run.Folder
        $result
    }
}

function Invoke-ADFlowHireRecord {
    # One HR row. -WhatIf reaches it through the caller's $WhatIfPreference.
    [CmdletBinding(SupportsShouldProcess)]
    param($Record, $Config, $Directory, $Run, $Reserved, [string] $Mode, [object[]] $FolderAdmins = @(),
        [string] $HomeRoot, [string] $HomeRootIssue)

    $warnings = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($warning in $Record.Warnings) { $warnings.Add($warning) }
    $result = [pscustomobject][ordered]@{
        Row               = $Record.Row
        EmployeeId        = $Record.EmployeeId
        DisplayName       = ('{0} {1}' -f $Record.FirstName, $Record.LastName).Trim()
        SamAccountName    = $null
        UserPrincipalName = $null
        Ou                = $null
        Groups            = @()
        Mail              = $null
        HomeFolder        = $null
        WelcomeMessage    = $null
        Status            = $null
        Message           = ''
        Warnings          = $warnings
        Password          = $null
    }
    $audit = @{ Run = $Run; EmployeeId = $Record.EmployeeId }

    # 1. Rows with errors are rejected as a whole
    if ($Record.Errors.Count) {
        $result.Status = 'Rejected'
        $result.Message = $Record.Errors -join '; '
        Write-ADFlowAuditEntry @audit -Action ValidateRow -Target "row $($Record.Row)" -Status Rejected -Message $result.Message
        return Complete-ADFlowResult $result
    }

    # 2. Already in the directory: nothing to do
    $existing = $Directory.FindUserByEmployeeId($Record.EmployeeId)
    if ($null -ne $existing) {
        $result.Status = 'Skipped'
        $result.SamAccountName = $existing.samAccountName
        $result.Message = "Employee $($Record.EmployeeId) already has the account $($existing.samAccountName)"
        Write-ADFlowAuditEntry @audit -Action CheckExisting -Target $existing.samAccountName -Status Skipped -Message $result.Message
        return Complete-ADFlowResult $result
    }

    # 3. Where it goes and what it gets
    $ou = Get-ADFlowDepartmentOu -Config $Config -Department $Record.Department
    $result.Ou = $ou
    if (-not $Directory.TestOu($ou)) {
        $result.Status = 'Failed'
        $result.Message = "The OU $ou of department '$($Record.Department)' does not exist in the directory"
        Write-ADFlowAuditEntry @audit -Action CheckOu -Target $ou -Status Failed -Message $result.Message
        return Complete-ADFlowResult $result
    }
    $groups = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($group in (Get-ADFlowGroupAssignment -Config $Config -Title $Record.Title).Groups) {
        if ($Directory.TestGroup($group)) { $groups.Add($group) }
        else { $warnings.Add("Group $group does not exist in the directory and was not assigned") }
    }
    $result.Groups = $groups.ToArray()

    $manager = $null
    if ($Record.Manager) {
        if ($null -ne $Directory.FindUser($Record.Manager)) { $manager = $Record.Manager }
        else { $warnings.Add("Manager $($Record.Manager) not found: the account has no manager") }
    }

    # 4. A free user name
    $taken = { param($candidate) ($null -ne $Directory.FindUser($candidate)) -or $Reserved.Contains($candidate) }.GetNewClosure()
    $maxLength = if ($Config.naming -and $Config.naming.maxLength) { [int] $Config.naming.maxLength } else { 20 }
    try {
        $sam = Get-ADFlowSamAccountName -FirstName $Record.FirstName -LastName $Record.LastName -Exists $taken -MaxLength $maxLength
    }
    catch {
        $result.Status = 'Failed'
        $result.Message = Get-ADFlowErrorMessage $_
        Write-ADFlowAuditEntry @audit -Action PickUserName -Target $result.DisplayName -Status Failed -Message $result.Message
        return Complete-ADFlowResult $result
    }
    [void] $Reserved.Add($sam)
    $result.SamAccountName = $sam
    $result.UserPrincipalName = '{0}@{1}' -f $sam, $Config.domain.upnSuffix
    $mailDomain = if ($Config.domain.mailDomain) { $Config.domain.mailDomain } else { $Config.domain.upnSuffix }
    $result.Mail = '{0}@{1}' -f $sam, $mailDomain

    # Personal folder: only when the root is reachable and the folder is new
    $homePath = $null
    if ($HomeRoot) {
        $candidatePath = Get-ADFlowHomeFolderPath -Root $HomeRoot -SamAccountName $sam
        if ($HomeRootIssue) {
            $warnings.Add($HomeRootIssue)
        }
        elseif (Test-Path -LiteralPath $candidatePath) {
            $warnings.Add("Personal folder $candidatePath already exists and was left as it is")
        }
        else { $homePath = $candidatePath }
    }
    $homeDrive = if ($Config.homeFolders -and $Config.homeFolders.drive) { [string] $Config.homeFolders.drive } else { $null }

    $spec = @{
        SamAccountName        = $sam
        UserPrincipalName     = $result.UserPrincipalName
        GivenName             = $Record.FirstName
        Surname               = $Record.LastName
        DisplayName           = $result.DisplayName
        EmployeeId            = $Record.EmployeeId
        Department            = $Record.Department
        Title                 = $Record.Title
        Manager               = $manager
        Mail                  = $result.Mail
        Ou                    = $ou
        HomeDirectory         = $homePath
        HomeDrive             = $(if ($homePath) { $homeDrive } else { $null })
        Enabled               = $true
        ChangePasswordAtLogon = $true
    }
    $details = [ordered]@{}
    foreach ($key in 'SamAccountName', 'UserPrincipalName', 'DisplayName', 'GivenName', 'Surname', 'EmployeeId',
        'Department', 'Title', 'Manager', 'Mail', 'Ou', 'HomeDirectory', 'HomeDrive', 'Enabled', 'ChangePasswordAtLogon') {
        $details[$key] = $spec[$key]
    }
    if ($Record.StartDate) { $details.StartDate = $Record.StartDate.ToString('yyyy-MM-dd') }

    # 5. Dry run and -WhatIf stop here, with the plan in the log
    $target = "$sam ($($result.DisplayName)) in $ou"
    $plannedStatus = $null
    if ($Mode -eq 'DryRun') { $plannedStatus = 'Planned' }
    elseif (-not $PSCmdlet.ShouldProcess($target, 'Create user')) { $plannedStatus = 'WhatIf' }
    if ($plannedStatus) {
        $result.Status = $plannedStatus
        Write-ADFlowAuditEntry @audit -Action CreateUser -Target $sam -Status $plannedStatus -Details $details
        foreach ($group in $groups) {
            Write-ADFlowAuditEntry @audit -Action AddGroupMember -Target $sam -Status $plannedStatus -Details @{ Group = $group }
        }
        if ($homePath) {
            # The account does not exist yet, so the user entry has no SID
            $acl = Get-ADFlowHomeFolderAcl -User ([ordered]@{ Name = $sam; Sid = $null }) -Admins $FolderAdmins
            Write-ADFlowAuditEntry @audit -Action CreateHomeFolder -Target $sam -Status $plannedStatus -Details ([ordered]@{ Path = $homePath; Acl = $acl })
            $result.HomeFolder = $homePath
        }
        return Complete-ADFlowResult $result
    }

    # 6. Create the account
    $passwordLength = if ($Config.password -and $Config.password.length) { [int] $Config.password.length } else { 16 }
    $spec.Password = Get-ADFlowRandomPassword -Length $passwordLength
    try {
        [void] $Directory.NewUser($spec)
    }
    catch {
        $result.Status = 'Failed'
        $result.Message = Get-ADFlowErrorMessage $_
        Write-ADFlowAuditEntry @audit -Action CreateUser -Target $sam -Status Failed -Message $result.Message -Details $details
        return Complete-ADFlowResult $result
    }
    $result.Password = $spec.Password
    $result.Status = 'Created'
    Write-ADFlowAuditEntry @audit -Action CreateUser -Target $sam -Status Succeeded -Details $details `
        -Undo ([ordered]@{ Action = 'RemoveUser'; SamAccountName = $sam })

    # 7. Groups: a failure here is a warning, the account already exists
    $added = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($group in $groups) {
        if (-not $PSCmdlet.ShouldProcess($sam, "Add to group $group")) { continue }
        try {
            $Directory.AddGroupMember($group, $sam)
            $added.Add($group)
            Write-ADFlowAuditEntry @audit -Action AddGroupMember -Target $sam -Status Succeeded -Details @{ Group = $group } `
                -Undo ([ordered]@{ Action = 'RemoveGroupMember'; Group = $group; SamAccountName = $sam })
        }
        catch {
            $reason = Get-ADFlowErrorMessage $_
            $warnings.Add("Could not add to $($group): $reason")
            Write-ADFlowAuditEntry @audit -Action AddGroupMember -Target $sam -Status Failed -Details @{ Group = $group } -Message $reason
        }
    }
    $result.Groups = $added.ToArray()

    # 8. Personal folder with its permissions: a failure is a warning too
    if ($homePath -and $PSCmdlet.ShouldProcess($homePath, 'Create personal folder')) {
        $acl = $null
        try {
            $acl = Get-ADFlowHomeFolderAcl -User ([ordered]@{ Name = $sam; Sid = $Directory.GetUserSid($sam) }) -Admins $FolderAdmins
            Invoke-ADFlowAction -Directory $Directory -Action ([ordered]@{ Action = 'CreateHomeFolder'; Path = $homePath; Acl = $acl })
            $result.HomeFolder = $homePath
            Write-ADFlowAuditEntry @audit -Action CreateHomeFolder -Target $sam -Status Succeeded -Details ([ordered]@{ Path = $homePath; Acl = $acl }) `
                -Undo ([ordered]@{ Action = 'RemoveFolder'; Path = $homePath })
        }
        catch {
            $reason = Get-ADFlowErrorMessage $_
            $warnings.Add("Could not create the personal folder $($homePath): $reason")
            Write-ADFlowAuditEntry @audit -Action CreateHomeFolder -Target $sam -Status Failed -Details ([ordered]@{ Path = $homePath; Acl = $acl }) -Message $reason
        }
    }
    return Complete-ADFlowResult $result
}

function Complete-ADFlowResult {
    # Turns the warning list into an array and fills the message when there is none
    param($Result)
    $Result.Warnings = @($Result.Warnings)
    if (-not $Result.Message -and $Result.Warnings.Count) { $Result.Message = $Result.Warnings -join '; ' }
    return $Result
}
