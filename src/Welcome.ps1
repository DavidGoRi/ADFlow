#Requires -Version 5.1
<#
.SYNOPSIS
    Welcome message for each new hire, written as an unsent email (.eml).

.DESCRIPTION
    The message is built from an HTML template with {{Placeholders}} and saved
    in <run folder>\welcome\<sAMAccountName>.eml. Nothing is sent: the .eml
    has the X-Unsent header, so Outlook opens it as a draft that IT can check
    and send. It goes to the manager (or to the new account when there is no
    manager), with a copy to the helpdesk.

    The temporary password is never part of the message.

    Placeholders: GivenName, DisplayName, SamAccountName, UserPrincipalName,
    Mail, Department, Title, StartDate, ManagerName, HomeFolder, CompanyName,
    HelpdeskEmail, HelpdeskPhone.
#>

function ConvertTo-ADFlowHtmlText {
    <#
    .SYNOPSIS
        Escapes the five HTML special characters and keeps accents readable
        (WebUtility.HtmlEncode would turn "José" into "Jos&#233;").
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [AllowNull()] [string] $Text)
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

function Expand-ADFlowTemplate {
    <#
    .SYNOPSIS
        Replaces {{Name}} placeholders. Fails on any placeholder without a value.
    .PARAMETER Html
        Encode the values for HTML, so a name like "O'Connor <x>" cannot break
        the page.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Template,
        [Parameter(Mandatory)] [hashtable] $Values,
        [switch] $Html
    )
    $missing = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $output = New-Object -TypeName System.Text.StringBuilder
    $position = 0
    foreach ($match in [regex]::Matches($Template, '\{\{\s*([A-Za-z]+)\s*\}\}')) {
        [void] $output.Append($Template, $position, $match.Index - $position)
        $position = $match.Index + $match.Length
        $name = $match.Groups[1].Value
        if (-not $Values.ContainsKey($name)) {
            if (-not $missing.Contains($name)) { $missing.Add($name) }
            continue
        }
        $text = [string] $Values[$name]
        if ($Html) { $text = ConvertTo-ADFlowHtmlText -Text $text }
        [void] $output.Append($text)
    }
    [void] $output.Append($Template, $position, $Template.Length - $position)
    if ($missing.Count) { throw "The template uses unknown placeholder(s): $($missing -join ', ')" }
    return $output.ToString()
}

function ConvertTo-ADFlowMimeHeader {
    # RFC 2047 encoded word, so accents survive in the subject
    param([string] $Text)
    if ($Text -match '^[\x20-\x7E]*$') { return $Text }
    return '=?utf-8?B?{0}?=' -f [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function Export-ADFlowWelcomeMessage {
    <#
    .SYNOPSIS
        Writes the welcome .eml of one new hire and returns its path.
    .PARAMETER Result
        The onboarding result (SamAccountName, DisplayName, Mail, HomeFolder...).
    .PARAMETER Record
        The HR row (FirstName, Department, Title, Manager, StartDate).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $Directory,
        [Parameter(Mandatory)] [string] $Folder
    )
    $settings = $Config.welcome
    $templatePath = [string] $settings.template
    if (-not [IO.Path]::IsPathRooted($templatePath)) { $templatePath = Join-Path -Path $Config.ConfigDirectory -ChildPath $templatePath }
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "Welcome template not found: $templatePath" }

    $manager = $null
    if ($Record.Manager) { $manager = $Directory.FindUser($Record.Manager) }
    $managerName = if ($manager -and $manager.displayName) { [string] $manager.displayName } else { 'team' }
    $managerMail = if ($manager) { if ($manager.mail) { [string] $manager.mail } else { [string] $manager.userPrincipalName } } else { '' }

    $values = @{
        GivenName         = ($Record.FirstName -split '\s+')[0]
        DisplayName       = $Result.DisplayName
        SamAccountName    = $Result.SamAccountName
        UserPrincipalName = $Result.UserPrincipalName
        Mail              = $Result.Mail
        Department        = $Record.Department
        Title             = $Record.Title
        StartDate         = $(if ($Record.StartDate) { $Record.StartDate.ToString('yyyy-MM-dd') } else { 'their first day' })
        ManagerName       = $managerName
        HomeFolder        = $(if ($Result.HomeFolder) { $Result.HomeFolder } else { 'none' })
        CompanyName       = [string] $settings.companyName
        HelpdeskEmail     = [string] $settings.helpdeskEmail
        HelpdeskPhone     = [string] $settings.helpdeskPhone
    }
    $body = Expand-ADFlowTemplate -Template ([IO.File]::ReadAllText($templatePath)) -Values $values -Html
    $subjectTemplate = if ($settings.subject) { [string] $settings.subject } else { 'Welcome, {{GivenName}}' }
    $subject = Expand-ADFlowTemplate -Template $subjectTemplate -Values $values

    $to = if ($managerMail) { $managerMail } else { $Result.Mail }
    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $lines.Add('X-Unsent: 1')
    if ($settings.from) { $lines.Add("From: $($settings.from)") }
    $lines.Add("To: $to")
    if ($settings.helpdeskEmail -and $settings.helpdeskEmail -ne $to) { $lines.Add("Cc: $($settings.helpdeskEmail)") }
    $lines.Add("Subject: $(ConvertTo-ADFlowMimeHeader $subject)")
    $lines.Add('MIME-Version: 1.0')
    $lines.Add('Content-Type: text/html; charset=utf-8')
    $lines.Add('Content-Transfer-Encoding: base64')
    $lines.Add('')
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))
    for ($i = 0; $i -lt $encoded.Length; $i += 76) {
        $lines.Add($encoded.Substring($i, [Math]::Min(76, $encoded.Length - $i)))
    }

    [void] [IO.Directory]::CreateDirectory($Folder)
    $path = Join-Path -Path $Folder -ChildPath "$($Result.SamAccountName).eml"
    # Mail files use CRLF line ends and plain ASCII headers
    [IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), (New-Object -TypeName System.Text.ASCIIEncoding))
    return $path
}

function ConvertFrom-ADFlowWelcomeMessage {
    <#
    .SYNOPSIS
        Reads back a welcome .eml: headers and decoded HTML body (for checks).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $text = [IO.File]::ReadAllText($Path)
    $split = $text.IndexOf("`r`n`r`n")
    $headers = @{}
    foreach ($line in ($text.Substring(0, $split) -split "`r`n")) {
        $name, $value = $line -split ':\s*', 2
        $headers[$name] = $value
    }
    $subject = $headers['Subject']
    if ($subject -match '^=\?utf-8\?B\?(.+)\?=$') { $subject = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) }
    $body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($text.Substring($split + 4) -replace '\s', '')))
    return [pscustomobject]@{ Headers = $headers; Subject = $subject; Body = $body }
}
