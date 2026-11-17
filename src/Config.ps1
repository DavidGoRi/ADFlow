#Requires -Version 5.1
<#
.SYNOPSIS
    Settings: domain, departments (OU) and roles (groups).

.DESCRIPTION
    Departments and job titles are matched without regard to case, accents or
    extra spaces, so "Recursos  humanos" in the HR file still finds a
    "Recursos Humanos" entry.
#>

function Get-ADFlowConfig {
    <#
    .SYNOPSIS
        Loads and validates a settings file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -Path $Path -PathType Leaf)) { throw "Settings file not found: $Path" }
    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    try {
        $config = [IO.File]::ReadAllText($fullPath) | ConvertFrom-Json
    }
    catch {
        throw "Settings file is not valid JSON: $Path ($($_.Exception.Message))"
    }

    $problems = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if (-not $config.domain -or -not $config.domain.upnSuffix) { $problems.Add('domain.upnSuffix is required') }
    if (-not $config.departments -or @($config.departments.PSObject.Properties).Count -eq 0) {
        $problems.Add('at least one department is required')
    }
    else {
        foreach ($department in $config.departments.PSObject.Properties) {
            if (-not $department.Value.ou -or $department.Value.ou -notmatch '^OU=') {
                $problems.Add("department '$($department.Name)' needs an 'ou' distinguished name (OU=...)")
            }
        }
    }
    if ($config.roles) {
        foreach ($role in $config.roles.PSObject.Properties) {
            if (@($role.Value | Where-Object { $_ -is [string] -and $_.Trim() }).Count -ne @($role.Value).Count) {
                $problems.Add("role '$($role.Name)' must be a list of group names")
            }
        }
    }
    if ($config.password -and $config.password.length -and [int] $config.password.length -lt 12) {
        $problems.Add('password.length must be 12 or more')
    }
    if ($config.welcome -and -not $config.welcome.template) { $problems.Add('welcome.template is required when there is a welcome section') }
    if ($problems.Count) { throw "Invalid settings in ${Path}: $($problems -join '; ')" }
    # Relative paths in the settings (the welcome template) are relative to the file
    $config | Add-Member -NotePropertyName ConfigDirectory -NotePropertyValue (Split-Path -Path $fullPath -Parent) -Force
    return $config
}

function ConvertTo-ADFlowMatchKey {
    # "  Recursos   Humanos " -> "recursos humanos"
    param([string] $Text)
    if (-not $Text) { return '' }
    return ((ConvertTo-ADFlowAscii -Text $Text) -replace '\s+', ' ').Trim()
}

function Find-ADFlowConfigEntry {
    # Looks up a property of a settings section by its normalised name
    param($Section, [string] $Name)
    if (-not $Section) { return $null }
    $key = ConvertTo-ADFlowMatchKey -Text $Name
    foreach ($property in $Section.PSObject.Properties) {
        if ((ConvertTo-ADFlowMatchKey -Text $property.Name) -eq $key) { return $property }
    }
    return $null
}

function Get-ADFlowDepartmentOu {
    <#
    .SYNOPSIS
        The OU for a department, or $null when the department is not configured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Department
    )
    $entry = Find-ADFlowConfigEntry -Section $Config.departments -Name $Department
    if ($entry) { return [string] $entry.Value.ou }
    return $null
}

function Get-ADFlowGroupAssignment {
    <#
    .SYNOPSIS
        The groups for a job title: the default groups plus the role's groups.
    .OUTPUTS
        An object with Groups (string[], no duplicates) and RoleFound (bool).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Title
    )
    $groups = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $entry = Find-ADFlowConfigEntry -Section $Config.roles -Name $Title
    foreach ($group in @($Config.defaultGroups) + @(if ($entry) { $entry.Value })) {
        if ($group -and $seen.Add($group)) { $groups.Add($group) }
    }
    return [pscustomobject]@{ Groups = $groups.ToArray(); RoleFound = [bool] $entry }
}
