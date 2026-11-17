#Requires -Version 5.1
<#
.SYNOPSIS
    Reads and validates the HR file of new hires.

.DESCRIPTION
    The file is a UTF-8 CSV separated by commas or semicolons (Excel in
    Spanish saves with semicolons). Columns:

      EmployeeId, FirstName, LastName, Department, Title  required
      Manager                                             optional, sAMAccountName
      StartDate                                           optional, yyyy-MM-dd

    A row with errors is returned with its Errors filled in and is not
    processed; the rest of the file goes on. Warnings do not stop a row.
#>

$script:ADFlowHireColumns = @('EmployeeId', 'FirstName', 'LastName', 'Department', 'Title')
$script:ADFlowOptionalHireColumns = @('Manager', 'StartDate')

function Import-ADFlowHireFile {
    <#
    .SYNOPSIS
        Returns one object per row with the values, Errors and Warnings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Config
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) { throw "HR file not found: $Path" }
    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    # ReadAllLines detects the BOM and defaults to UTF-8
    $lines = @([IO.File]::ReadAllLines($fullPath) | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { throw "HR file is empty: $Path" }

    $header = $lines[0]
    $delimiter = if (($header.Split(';').Count) -gt ($header.Split(',').Count)) { ';' } else { ',' }
    $columns = @($header.Split($delimiter) | ForEach-Object { $_.Trim().Trim('"') })
    $missing = @($script:ADFlowHireColumns | Where-Object { $columns -notcontains $_ })
    if ($missing.Count) { throw "HR file $Path is missing the column(s): $($missing -join ', ')" }

    $rows = @($lines | ConvertFrom-Csv -Delimiter $delimiter)
    $seenIds = @{}
    $rowNumber = 1
    foreach ($row in $rows) {
        $rowNumber++
        $errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $warnings = New-Object -TypeName 'System.Collections.Generic.List[string]'

        $values = @{}
        foreach ($column in $script:ADFlowHireColumns + $script:ADFlowOptionalHireColumns) {
            $value = if ($row.PSObject.Properties[$column]) { [string] $row.$column } else { '' }
            $values[$column] = $value.Trim()
        }
        foreach ($column in $script:ADFlowHireColumns) {
            if (-not $values[$column]) { $errors.Add("$column is empty") }
        }

        $employeeId = $values.EmployeeId
        if ($employeeId) {
            if ($employeeId -notmatch '^[A-Za-z0-9-]{1,16}$') {
                $errors.Add("EmployeeId '$employeeId' must be 1-16 letters, digits or hyphens")
            }
            elseif ($seenIds.ContainsKey($employeeId)) {
                $errors.Add("EmployeeId '$employeeId' is repeated (first on row $($seenIds[$employeeId]))")
            }
            else {
                $seenIds[$employeeId] = $rowNumber
            }
        }

        if ($values.FirstName -and $values.LastName) {
            try { [void] (Split-ADFlowPersonName -FirstName $values.FirstName -LastName $values.LastName) }
            catch { $errors.Add($_.Exception.Message) }
        }

        if ($values.Department -and -not (Get-ADFlowDepartmentOu -Config $Config -Department $values.Department)) {
            $errors.Add("Department '$($values.Department)' has no OU in the settings")
        }
        if ($values.Title -and -not (Get-ADFlowGroupAssignment -Config $Config -Title $values.Title).RoleFound) {
            $warnings.Add("Title '$($values.Title)' has no role in the settings: only the default groups are given")
        }

        $startDate = $null
        if ($values.StartDate) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact($values.StartDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None, [ref] $parsed)) {
                $startDate = $parsed
            }
            else {
                $errors.Add("StartDate '$($values.StartDate)' is not a yyyy-MM-dd date")
            }
        }

        [pscustomobject]@{
            Row        = $rowNumber   # the header is row 1; blank lines are not counted
            EmployeeId = $employeeId
            FirstName  = $values.FirstName
            LastName   = $values.LastName
            Department = $values.Department
            Title      = $values.Title
            Manager    = $values.Manager
            StartDate  = $startDate
            Errors     = $errors.ToArray()
            Warnings   = $warnings.ToArray()
        }
    }
}
