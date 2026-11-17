#Requires -Version 5.1
<#
.SYNOPSIS
    Directory and folder changes described as data.

.DESCRIPTION
    Offboarding and rollback express every change as a small object, for
    example @{ Action = 'MoveUser'; SamAccountName = 'ana.soto'; TargetOu = '...' }.
    The same object is written to the audit trail, and the "undo" of each
    entry is another action of this list. Undo-ADFlowRun reads them back from
    JSON and runs them with Invoke-ADFlowAction, so a change and its reversal
    always go through the same code.

      Action             Fields
      SetEnabled         SamAccountName, Enabled
      SetDescription     SamAccountName, Description
      AddGroupMember     Group, SamAccountName
      RemoveGroupMember  Group, SamAccountName
      MoveUser           SamAccountName, TargetOu
      RemoveUser         SamAccountName
      MoveFolder         Path, Destination
      CreateHomeFolder   Path, Acl (entries with Identity, Sid, Rights)
      RemoveFolder       Path (only when it is empty)
#>

function Get-ADFlowActionValue {
    # Reads a field from a hashtable or from an object parsed from JSON
    param($Action, [string] $Name)
    if ($Action -is [Collections.IDictionary]) { return $Action[$Name] }
    $property = $Action.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-ADFlowActionTarget {
    <#
    .SYNOPSIS
        What an action changes: the account, or the folder for MoveFolder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Action)
    $sam = Get-ADFlowActionValue $Action 'SamAccountName'
    if ($sam) { return [string] $sam }
    return [string] (Get-ADFlowActionValue $Action 'Path')
}

function Get-ADFlowActionText {
    <#
    .SYNOPSIS
        A short description for -WhatIf messages: "Remove from group GG-Sales".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Action)
    $value = @{}
    foreach ($name in 'Action', 'Enabled', 'Description', 'Group', 'TargetOu', 'Destination') {
        $value[$name] = Get-ADFlowActionValue $Action $name
    }
    switch ($value.Action) {
        'SetEnabled' { if ($value.Enabled) { return 'Enable account' } else { return 'Disable account' } }
        'SetDescription' { return "Set description '$($value.Description)'" }
        'AddGroupMember' { return "Add to group $($value.Group)" }
        'RemoveGroupMember' { return "Remove from group $($value.Group)" }
        'MoveUser' { return "Move to $($value.TargetOu)" }
        'RemoveUser' { return 'Delete account' }
        'MoveFolder' { return "Move folder to $($value.Destination)" }
        'CreateHomeFolder' { return 'Create personal folder' }
        'RemoveFolder' { return 'Delete empty folder' }
        default { return [string] $value.Action }
    }
}

function Invoke-ADFlowAction {
    <#
    .SYNOPSIS
        Runs one action against the directory provider or the file system.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Directory,
        [Parameter(Mandatory)] $Action
    )
    $name = Get-ADFlowActionValue $Action 'Action'
    $sam = Get-ADFlowActionValue $Action 'SamAccountName'
    switch ($name) {
        'SetEnabled' { $Directory.SetEnabled($sam, [bool] (Get-ADFlowActionValue $Action 'Enabled')) }
        'SetDescription' { $Directory.SetDescription($sam, [string] (Get-ADFlowActionValue $Action 'Description')) }
        'AddGroupMember' { $Directory.AddGroupMember((Get-ADFlowActionValue $Action 'Group'), $sam) }
        'RemoveGroupMember' { $Directory.RemoveGroupMember((Get-ADFlowActionValue $Action 'Group'), $sam) }
        'MoveUser' { $Directory.MoveUser($sam, (Get-ADFlowActionValue $Action 'TargetOu')) }
        'RemoveUser' { $Directory.RemoveUser($sam) }
        'MoveFolder' { Move-ADFlowFolder -Path (Get-ADFlowActionValue $Action 'Path') -Destination (Get-ADFlowActionValue $Action 'Destination') }
        'CreateHomeFolder' { New-ADFlowHomeFolder -Path (Get-ADFlowActionValue $Action 'Path') -Acl @(Get-ADFlowActionValue $Action 'Acl') -Confirm:$false }
        'RemoveFolder' { Remove-ADFlowEmptyFolder -Path (Get-ADFlowActionValue $Action 'Path') -Confirm:$false }
        default { throw "Unknown action '$name'" }
    }
}

function Get-ADFlowErrorMessage {
    <#
    .SYNOPSIS
        The message of the original error. Calling a provider method wraps it
        in "Exception calling ... with ... argument(s)".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [Management.Automation.ErrorRecord] $ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($exception -is [Management.Automation.MethodInvocationException] -and $exception.InnerException) {
        $exception = $exception.InnerException
    }
    return $exception.Message
}
