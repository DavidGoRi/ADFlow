#Requires -Version 5.1
<#
.SYNOPSIS
    Regenerates the pictures of the README from the live demo.

.DESCRIPTION
    Builds the demo (tools/Build-Demo.ps1, fictitious data only) in a
    temporary folder and writes to docs/:
      onboarding-report.png, offboarding-report.png, welcome-email.png
      social-preview.png    from tools/demo/social.html (1280x640, for the
                            repository settings on GitHub)
      console.gif           the onboarding and offboarding as they look in
                            the console, line by line

    Needs Microsoft Edge (headless screenshots) and ffmpeg (the GIF) on the
    computer that runs it; it is a maintenance script, not part of ADFlow.

.EXAMPLE
    .\tools\Update-Screenshots.ps1
#>
[CmdletBinding()]
param(
    [string] $EdgePath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    [string] $FfmpegPath = 'ffmpeg'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$docs = Join-Path $root 'docs'
if (-not (Test-Path -LiteralPath $EdgePath)) { throw "Microsoft Edge not found: $EdgePath" }
$work = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('adflow-shots-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$site = Join-Path $work 'site'
[void] (& (Join-Path $PSScriptRoot 'Build-Demo.ps1') -OutputPath $site)

function Save-Screenshot([string] $Page, [string] $Png, [int] $Width, [int] $Height) {
    # A fresh profile each time: Edge keeps the old one locked for a while
    $userData = Join-Path $work ('edge-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $arguments = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--lang=en-US', "--user-data-dir=$userData",
        "--window-size=$Width,$Height", "--screenshot=$Png", $Page)
    Start-Process -FilePath $EdgePath -ArgumentList $arguments -Wait -WindowStyle Hidden
    if (-not (Test-Path -LiteralPath $Png)) { throw "No screenshot of $Page" }
}
function ConvertTo-FileUri([string] $Path) { return ([Uri] $Path).AbsoluteUri }

Save-Screenshot (ConvertTo-FileUri (Join-Path $site 'onboarding.html')) (Join-Path $docs 'onboarding-report.png') 1280 1020
Save-Screenshot (ConvertTo-FileUri (Join-Path $site 'offboarding.html')) (Join-Path $docs 'offboarding-report.png') 1280 940
Save-Screenshot (ConvertTo-FileUri (Join-Path $site 'welcome.html')) (Join-Path $docs 'welcome-email.png') 760 660
Save-Screenshot (ConvertTo-FileUri (Join-Path $PSScriptRoot 'demo\social.html')) (Join-Path $docs 'social-preview.png') 1280 640

# The console GIF: the two console blocks of the demo, shown line by line
$index = [IO.File]::ReadAllText((Join-Path $site 'index.html'))
$blocks = @([regex]::Matches($index, '(?s)<pre class="term">(.*?)</pre>') | ForEach-Object { $_.Groups[1].Value })
$style = @'
<style>
  html, body { margin: 0; background: #0c0c0c; }
  pre { margin: 0; padding: 18px 22px; color: #cccccc; font: 15px/1.45 Consolas, "Cascadia Mono", monospace; white-space: pre; overflow: hidden; }
  .prompt { color: #61d6d6; } .ok { color: #16c60c; } .plan { color: #3b78ff; } .warn { color: #f9f1a5; }
  .bad { color: #e74856; } .skip, .msg { color: #767676; }
</style>
'@
$frames = New-Object -TypeName 'System.Collections.Generic.List[object]'
$frameFolder = Join-Path $work 'frames'
[void] [IO.Directory]::CreateDirectory($frameFolder)
foreach ($block in $blocks[0..1]) {
    $lines = $block -split "`n"
    # The command is typed, then each output line appears
    $prompt = $lines[0]
    $command = [regex]::Match($prompt, '</span> (.*)$').Groups[1].Value
    for ($typed = 0; $typed -le $command.Length; $typed += 6) {
        $frames.Add(@{ Html = '<span class="prompt">PS&gt;</span> ' + $command.Substring(0, [Math]::Min($typed, $command.Length)) + '_'; Seconds = 0.06 })
    }
    for ($count = 1; $count -le $lines.Count; $count++) {
        $seconds = if ($count -eq $lines.Count) { 3.5 } else { 0.18 }
        $frames.Add(@{ Html = ($lines[0..($count - 1)] -join "`n"); Seconds = $seconds })
    }
}
$list = New-Object -TypeName 'System.Collections.Generic.List[string]'
for ($i = 0; $i -lt $frames.Count; $i++) {
    $page = Join-Path $frameFolder ('frame{0:d3}.html' -f $i)
    $png = Join-Path $frameFolder ('frame{0:d3}.png' -f $i)
    [IO.File]::WriteAllText($page, "<!DOCTYPE html><html><head><meta charset=`"utf-8`">$style</head><body><pre>$($frames[$i].Html)</pre></body></html>",
        (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    Save-Screenshot (ConvertTo-FileUri $page) $png 1180 560
    $list.Add("file '$($png.Replace('\', '/'))'")
    $list.Add('duration {0}' -f $frames[$i].Seconds.ToString([Globalization.CultureInfo]::InvariantCulture))
}
$list.Add("file '$($png.Replace('\', '/'))'")   # the concat demuxer ignores the last duration otherwise
$listPath = Join-Path $work 'frames.txt'
[IO.File]::WriteAllLines($listPath, [string[]] $list)
$gif = Join-Path $docs 'console.gif'
$filter = 'scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=none'
& $FfmpegPath -y -loglevel error -f concat -safe 0 -i $listPath -filter_complex $filter -loop 0 $gif
if ($LASTEXITCODE) { throw "ffmpeg failed ($LASTEXITCODE)" }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $docs -File | Select-Object Name, @{ Name = 'KB'; Expression = { [Math]::Round($_.Length / 1KB) } }
