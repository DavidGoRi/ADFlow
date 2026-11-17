#Requires -Version 5.1
<#
.SYNOPSIS
    Temporary passwords from a cryptographic random generator.

.DESCRIPTION
    Every password has at least one upper case letter, one lower case letter,
    one digit and one symbol, which meets the Active Directory complexity rule.
    Characters that are easy to confuse when read aloud or copied (O/0, I/l/1)
    are left out. The password is returned as a SecureString and is never
    written to the audit log.
#>

$script:ADFlowPasswordSets = @(
    'ABCDEFGHJKLMNPQRSTUVWXYZ'
    'abcdefghijkmnopqrstuvwxyz'
    '23456789'
    '!#$%*+-=?@_'
)
$script:ADFlowRandom = [Security.Cryptography.RandomNumberGenerator]::Create()

function Get-ADFlowRandomIndex {
    <#
    .SYNOPSIS
        A uniform random number from 0 to Count - 1 (rejection sampling, no modulo bias).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [ValidateRange(1, 65536)] [int] $Count)

    $range = [uint64] 4294967296
    $limit = $range - ($range % [uint64] $Count)
    $bytes = New-Object -TypeName byte[] -ArgumentList 4
    do {
        $script:ADFlowRandom.GetBytes($bytes)
        $value = [uint64] [BitConverter]::ToUInt32($bytes, 0)
    } while ($value -ge $limit)
    return [int] ($value % [uint64] $Count)
}

function Get-ADFlowRandomPassword {
    <#
    .SYNOPSIS
        Generates a temporary password.
    .OUTPUTS
        System.Security.SecureString
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param([ValidateRange(12, 128)] [int] $Length = 16)

    $characters = New-Object -TypeName 'System.Collections.Generic.List[char]'
    # One character of each kind, then the rest from all of them
    foreach ($set in $script:ADFlowPasswordSets) {
        $characters.Add($set[(Get-ADFlowRandomIndex -Count $set.Length)])
    }
    $all = -join $script:ADFlowPasswordSets
    while ($characters.Count -lt $Length) {
        $characters.Add($all[(Get-ADFlowRandomIndex -Count $all.Length)])
    }
    # Fisher-Yates shuffle, so the guaranteed characters are not always first
    for ($i = $characters.Count - 1; $i -gt 0; $i--) {
        $j = Get-ADFlowRandomIndex -Count ($i + 1)
        $swap = $characters[$i]; $characters[$i] = $characters[$j]; $characters[$j] = $swap
    }

    $secure = New-Object -TypeName System.Security.SecureString
    foreach ($character in $characters) { $secure.AppendChar($character) }
    $secure.MakeReadOnly()
    $characters.Clear()
    return $secure
}
