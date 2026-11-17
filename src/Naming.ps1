#Requires -Version 5.1
<#
.SYNOPSIS
    User name rules: accent folding, name splitting and unique sAMAccountName.

.DESCRIPTION
    The format is <first given name>.<first surname>, all lower case ASCII:
    "María José García López" becomes maria.garcia. When that name is taken,
    the initial of the second surname is added (maria.garcial) and, after
    that, a number (maria.garcia2, maria.garcia3...).

    Surname particles are kept with the surname they belong to, so
    "de la Fuente Ruiz" gives the surnames delafuente and ruiz.
#>

# Letters that Unicode decomposition does not turn into ASCII (lower case)
$script:ADFlowFoldedLetters = @{
    0x00DF = 'ss'   # sharp s
    0x00E6 = 'ae'   # ae ligature
    0x00F8 = 'o'    # o with stroke
    0x0142 = 'l'    # l with stroke
    0x0111 = 'd'    # d with stroke
    0x0153 = 'oe'   # oe ligature
    0x00FE = 'th'   # thorn
}

# Words that belong to the next surname ("de la Fuente" -> "delafuente")
$script:ADFlowSurnameParticles = @('de', 'del', 'la', 'las', 'los', 'da', 'das', 'do', 'dos', 'di', 'van', 'von', 'der', 'den', 'le')
# Words that join two surnames and are dropped ("Ortega y Gasset")
$script:ADFlowSurnameConnectors = @('y', 'i', 'e')

function ConvertTo-ADFlowAscii {
    <#
    .SYNOPSIS
        Lower-cases a text and removes accents: "Íñigo Peña" -> "inigo pena".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, ValueFromPipeline)] [AllowEmptyString()] [string] $Text)

    process {
        $decomposed = $Text.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
        $builder = New-Object -TypeName System.Text.StringBuilder
        foreach ($character in $decomposed.ToCharArray()) {
            $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
            if ($category -eq [Globalization.UnicodeCategory]::NonSpacingMark) { continue }
            $code = [int] $character
            if ($script:ADFlowFoldedLetters.ContainsKey($code)) {
                [void] $builder.Append($script:ADFlowFoldedLetters[$code])
            }
            else {
                [void] $builder.Append($character)
            }
        }
        return $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
    }
}

function ConvertTo-ADFlowNameWord {
    # Splits a name into clean words: hyphens and apostrophes join, the rest separates
    param([string] $Text)
    $ascii = (ConvertTo-ADFlowAscii -Text $Text) -replace '[\x27\x60\u2019-]', ''
    return @(($ascii -replace '[^a-z0-9]+', ' ').Trim() -split ' ' | Where-Object { $_ })
}

function Split-ADFlowPersonName {
    <#
    .SYNOPSIS
        Splits a person's name into clean given names and surnames.
    .OUTPUTS
        An object with Given (string[]) and Surnames (string[]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $FirstName,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $LastName
    )

    $given = @(ConvertTo-ADFlowNameWord -Text $FirstName)
    $surnames = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $pending = ''
    foreach ($word in (ConvertTo-ADFlowNameWord -Text $LastName)) {
        if ($script:ADFlowSurnameConnectors -contains $word) { continue }
        if ($script:ADFlowSurnameParticles -contains $word) { $pending += $word; continue }
        $surnames.Add($pending + $word)
        $pending = ''
    }
    # A surname made only of particles ("De La") is kept as it is
    if ($pending) { $surnames.Add($pending) }

    if ($given.Count -eq 0) { throw "The first name '$FirstName' has no usable letters" }
    if ($surnames.Count -eq 0) { throw "The last name '$LastName' has no usable letters" }

    return [pscustomobject]@{ Given = $given; Surnames = $surnames.ToArray() }
}

function Limit-ADFlowNameLength {
    # Shortens the base so that base + suffix fits; never ends the base in a dot
    param([string] $Base, [string] $Suffix, [int] $MaxLength)
    $room = $MaxLength - $Suffix.Length
    if ($Base.Length -gt $room) { $Base = $Base.Substring(0, $room).TrimEnd('.') }
    return $Base + $Suffix
}

function Get-ADFlowSamAccountName {
    <#
    .SYNOPSIS
        Returns the first free sAMAccountName for a person.
    .PARAMETER Exists
        A script block that receives a candidate name and returns $true when it
        is already taken. Onboarding passes one that asks the directory and also
        remembers the names given earlier in the same run.
    .PARAMETER MaxLength
        sAMAccountName allows 20 characters.
    .EXAMPLE
        Get-ADFlowSamAccountName -FirstName 'María José' -LastName 'García López' -Exists { param($n) $n -eq 'maria.garcia' }
        # maria.garcial
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $FirstName,
        [Parameter(Mandatory)] [string] $LastName,
        [scriptblock] $Exists = { $false },
        [ValidateRange(8, 64)] [int] $MaxLength = 20,
        [ValidateRange(2, 999)] [int] $MaxNumber = 99
    )

    $name = Split-ADFlowPersonName -FirstName $FirstName -LastName $LastName
    $base = '{0}.{1}' -f $name.Given[0], $name.Surnames[0]

    $candidates = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $candidates.Add((Limit-ADFlowNameLength -Base $base -Suffix '' -MaxLength $MaxLength))
    if ($name.Surnames.Count -gt 1) {
        $candidates.Add((Limit-ADFlowNameLength -Base $base -Suffix $name.Surnames[1].Substring(0, 1) -MaxLength $MaxLength))
    }
    for ($number = 2; $number -le $MaxNumber; $number++) {
        $candidates.Add((Limit-ADFlowNameLength -Base $base -Suffix ([string] $number) -MaxLength $MaxLength))
    }

    $tried = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        # Shortening can turn two candidates into the same name
        if (-not $tried.Add($candidate)) { continue }
        if (-not (& $Exists $candidate)) { return $candidate }
    }
    throw "No free user name for '$FirstName $LastName' after $($tried.Count) attempts (last: $candidate)"
}
