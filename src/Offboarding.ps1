#Requires -Version 5.1
<#
.SYNOPSIS
    Offboarding: closes the accounts of the HR file of leavers.

.DESCRIPTION
    For each valid row, in this order:
      1. finds the account by EmployeeId (or sAMAccountName);
      2. refuses protected accounts (offboarding.protectedAccounts) and
         members of protected groups (offboarding.protectedGroups);
      3. records the groups the account belongs to (RecordGroups entry);
      4. disables the account;
      5. writes the leave date and reason in its description;
      6. removes it from its groups, except offboarding.keepGroups;
      7. moves it to the leavers OU (offboarding.ou);
      8. moves its personal folder to offboarding.archiveRoot.

    Every change is logged with its reverse action, so Undo-ADFlowRun can
    restore the account, its groups, its OU and its folder.

    An account that is already disabled and in the leavers OU is skipped.
    If a step fails, the next steps of that person are not attempted; the
    steps already done stay in the log and can be undone.
#>

function Invoke-ADFlowOffboarding {
    <#
    .SYNOPSIS
        Processes an HR file of leavers and returns one result per row.
    .OUTPUTS
        Objects with Row, EmployeeId, SamAccountName, DisplayName, Status,
        Message, Warnings, Groups (removed), PreviousOu, ArchivedTo, RunId and
        RunFolder. Status is Offboarded, Planned, WhatIf, Skipped, Rejected or
        Failed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $CsvPath,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $Directory,
        [Parameter(Mandatory)] [string] $LogPath,
        [switch] $DryRun,
        # The day of the run, for the description and the archive folder name
        [datetime] $Date = (Get-Date)
    )

    $settings = Get-ADFlowOffboardingSetting -Config $Config
    if (-not $Directory.TestOu($settings.Ou)) { throw "The leavers OU $($settings.Ou) does not exist in the directory" }

    $mode = if ($DryRun) { 'DryRun' } elseif ($WhatIfPreference) { 'WhatIf' } else { 'Live' }
    $records = @(Import-ADFlowLeaverFile -Path $CsvPath)
    $run = Initialize-ADFlowRun -LogPath $LogPath -Operation Offboarding -Mode $mode -Provider $Directory.Name -Source $CsvPath

    $results = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $changed = $false
    foreach ($record in $records) {
        $result = Invoke-ADFlowLeaverRecord -Record $record -Settings $settings -Directory $Directory -Run $run -Mode $mode -Date $Date
        if ($result.Changed) { $changed = $true }
        $result.PSObject.Properties.Remove('Changed')
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

function Get-ADFlowOffboardingSetting {
    <#
    .SYNOPSIS
        The offboarding part of the settings, with defaults.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)
    $section = $Config.offboarding
    if (-not $section -or -not $section.ou) { throw 'The settings need offboarding.ou (the leavers OU) for offboarding' }
    $homeRoot = if ($Config.homeFolders) { [string] $Config.homeFolders.root } else { '' }
    # Checked once: an unreachable share can take seconds to answer
    $homeRootIssue = $null
    if ($homeRoot -and -not (Test-ADFlowFolder -Path $homeRoot)) {
        $homeRootIssue = "Home folder root $homeRoot is not reachable: the personal folder was not archived"
        $homeRoot = ''
    }
    return [pscustomobject]@{
        Ou                = [string] $section.ou
        HomeRoot          = $homeRoot
        HomeRootIssue     = $homeRootIssue
        ArchiveRoot       = [string] $section.archiveRoot
        KeepGroups        = @($section.keepGroups | Where-Object { $_ })
        ProtectedAccounts = @($section.protectedAccounts | Where-Object { $_ })
        ProtectedGroups   = @($section.protectedGroups | Where-Object { $_ })
    }
}

function Invoke-ADFlowLeaverRecord {
    # One leaver row. -WhatIf reaches it through the caller's $WhatIfPreference.
    [CmdletBinding(SupportsShouldProcess)]
    param($Record, $Settings, $Directory, $Run, [string] $Mode, [datetime] $Date)

    $warnings = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $result = [pscustomobject][ordered]@{
        Row            = $Record.Row
        EmployeeId     = $Record.EmployeeId
        SamAccountName = $Record.SamAccountName
        DisplayName    = ''
        Status         = $null
        Message        = ''
        Warnings       = $warnings
        Groups         = @()
        PreviousOu     = $null
        ArchivedTo     = $null
        Changed        = $false
    }
    $audit = @{ Run = $Run; EmployeeId = $Record.EmployeeId }
    $rowTarget = "row $($Record.Row)"

    # 1. Validation and lookup
    if ($Record.Errors.Count) {
        $result.Status = 'Rejected'
        $result.Message = $Record.Errors -join '; '
        Write-ADFlowAuditEntry @audit -Action ValidateRow -Target $rowTarget -Status Rejected -Message $result.Message
        return Complete-ADFlowResult $result
    }
    $user = $null
    if ($Record.EmployeeId) {
        $user = $Directory.FindUserByEmployeeId($Record.EmployeeId)
        if ($null -ne $user -and $Record.SamAccountName -and $user.samAccountName -ne $Record.SamAccountName) {
            $result.Status = 'Rejected'
            $result.Message = "EmployeeId $($Record.EmployeeId) belongs to $($user.samAccountName), not to $($Record.SamAccountName)"
            Write-ADFlowAuditEntry @audit -Action FindUser -Target $rowTarget -Status Rejected -Message $result.Message
            return Complete-ADFlowResult $result
        }
    }
    else {
        $user = $Directory.FindUser($Record.SamAccountName)
        # FindUser also matches UPN prefixes; offboarding needs the exact account
        if ($null -ne $user -and $user.samAccountName -ne $Record.SamAccountName) { $user = $null }
    }
    if ($null -eq $user) {
        $result.Status = 'Failed'
        $who = if ($Record.EmployeeId) { "EmployeeId $($Record.EmployeeId)" } else { $Record.SamAccountName }
        $result.Message = "No account found for $who"
        Write-ADFlowAuditEntry @audit -Action FindUser -Target $rowTarget -Status Failed -Message $result.Message
        return Complete-ADFlowResult $result
    }

    $sam = [string] $user.samAccountName
    $result.SamAccountName = $sam
    $result.EmployeeId = $user.employeeId
    $audit.EmployeeId = [string] $user.employeeId
    $result.DisplayName = [string] $user.displayName
    $result.PreviousOu = [string] $user.ou
    $groups = @($Directory.GetUserGroups($sam))

    # 2. Protected accounts are never touched
    $protectedBy = @($groups | Where-Object { $Settings.ProtectedGroups -contains $_ })
    if ($Settings.ProtectedAccounts -contains $sam -or $protectedBy.Count) {
        $result.Status = 'Rejected'
        $result.Message = if ($Settings.ProtectedAccounts -contains $sam) { "$sam is a protected account" } else { "$sam is a member of the protected group(s) $($protectedBy -join ', ')" }
        Write-ADFlowAuditEntry @audit -Action CheckProtected -Target $sam -Status Rejected -Message $result.Message
        return Complete-ADFlowResult $result
    }

    # 3. Already done
    if (-not $user.enabled -and $user.ou -eq $Settings.Ou) {
        $result.Status = 'Skipped'
        $result.Message = "$sam is already disabled and in the leavers OU"
        Write-ADFlowAuditEntry @audit -Action CheckOffboarded -Target $sam -Status Skipped -Message $result.Message
        return Complete-ADFlowResult $result
    }

    # 4. The plan: each step is an action and its reverse
    $leave = if ($Record.LeaveDate) { $Record.LeaveDate } else { $Date }
    $description = 'Left on {0}' -f $leave.ToString('yyyy-MM-dd')
    if ($Record.Reason) { $description += " ($($Record.Reason))" }
    $description += " - ADFlow $($Run.RunId)"

    $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
    if ($user.enabled) {
        $steps.Add(@{ Do = [ordered]@{ Action = 'SetEnabled'; SamAccountName = $sam; Enabled = $false }
                Undo = [ordered]@{ Action = 'SetEnabled'; SamAccountName = $sam; Enabled = $true } })
    }
    $steps.Add(@{ Do = [ordered]@{ Action = 'SetDescription'; SamAccountName = $sam; Description = $description }
            Undo = [ordered]@{ Action = 'SetDescription'; SamAccountName = $sam; Description = [string] $user.description } })
    $removed = @($groups | Where-Object { $Settings.KeepGroups -notcontains $_ })
    foreach ($group in $removed) {
        $steps.Add(@{ Do = [ordered]@{ Action = 'RemoveGroupMember'; Group = $group; SamAccountName = $sam }
                Undo = [ordered]@{ Action = 'AddGroupMember'; Group = $group; SamAccountName = $sam } })
    }
    if ($user.ou -ne $Settings.Ou) {
        $steps.Add(@{ Do = [ordered]@{ Action = 'MoveUser'; SamAccountName = $sam; TargetOu = $Settings.Ou }
                Undo = [ordered]@{ Action = 'MoveUser'; SamAccountName = $sam; TargetOu = [string] $user.ou } })
    }
    $archive = $null
    if ($Settings.HomeRootIssue) { $warnings.Add($Settings.HomeRootIssue) }
    $homeFolder = Get-ADFlowHomeFolderPath -Root $Settings.HomeRoot -SamAccountName $sam
    if ($homeFolder) {
        if (-not (Test-ADFlowFolder -Path $homeFolder)) {
            $warnings.Add("Personal folder $homeFolder not found: nothing to archive")
        }
        elseif (-not $Settings.ArchiveRoot) {
            $warnings.Add('offboarding.archiveRoot is not set: the personal folder was left in place')
        }
        else {
            $archive = Get-ADFlowArchiveFolderPath -ArchiveRoot $Settings.ArchiveRoot -SamAccountName $sam -Date $Date
            $steps.Add(@{ Do = [ordered]@{ Action = 'MoveFolder'; Path = $homeFolder; Destination = $archive }
                    Undo = [ordered]@{ Action = 'MoveFolder'; Path = $archive; Destination = $homeFolder } })
        }
    }

    # 5. Keep the group membership on record before anything changes
    $recordStatus = switch ($Mode) { 'DryRun' { 'Planned' } 'WhatIf' { 'WhatIf' } default { 'Succeeded' } }
    Write-ADFlowAuditEntry @audit -Action RecordGroups -Target $sam -Status $recordStatus `
        -Details ([ordered]@{ Groups = $groups; Ou = [string] $user.ou; Enabled = [bool] $user.enabled; Description = [string] $user.description })

    # 6. Run the steps
    $done = 0
    $planned = 0
    foreach ($step in $steps) {
        $details = [ordered]@{}
        foreach ($key in $step.Do.Keys) { if ($key -ne 'Action') { $details[$key] = $step.Do[$key] } }
        $actionName = $step.Do.Action
        if ($Mode -eq 'DryRun') {
            Write-ADFlowAuditEntry @audit -Action $actionName -Target $sam -Status Planned -Details $details
            $planned++
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($sam, (Get-ADFlowActionText -Action $step.Do))) {
            Write-ADFlowAuditEntry @audit -Action $actionName -Target $sam -Status WhatIf -Details $details
            $planned++
            continue
        }
        try {
            Invoke-ADFlowAction -Directory $Directory -Action $step.Do
        }
        catch {
            $reason = Get-ADFlowErrorMessage $_
            Write-ADFlowAuditEntry @audit -Action $actionName -Target $sam -Status Failed -Details $details -Message $reason
            $result.Status = 'Failed'
            $result.Message = "$(Get-ADFlowActionText -Action $step.Do) failed: $reason"
            if ($done) { $result.Message += " ($done earlier step(s) can be undone with Undo-ADFlowRun)" }
            $result.Changed = [bool] $done
            return Complete-ADFlowResult $result
        }
        Write-ADFlowAuditEntry @audit -Action $actionName -Target $sam -Status Succeeded -Details $details -Undo $step.Undo
        $done++
    }

    $result.Groups = $removed
    if ($archive) { $result.ArchivedTo = $archive }
    if ($Mode -eq 'DryRun') { $result.Status = 'Planned' }
    elseif ($done -eq 0 -and $planned) { $result.Status = 'WhatIf' }
    else { $result.Status = 'Offboarded'; $result.Changed = $true }
    return Complete-ADFlowResult $result
}
