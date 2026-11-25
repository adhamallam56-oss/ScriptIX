# Makes guide.html (one file, pictures inside) from GUIDE.md. Run it after every change to GUIDE.md.
$ErrorActionPreference = 'Stop'
$u8 = New-Object Text.UTF8Encoding($false)
$lines = [IO.File]::ReadAllLines("$PSScriptRoot\GUIDE.md", $u8)
$out = New-Object Text.StringBuilder; $toc = New-Object Text.StringBuilder
function Add-Line([string]$s) { [void]$out.Append($s).Append("`n") }
function Get-Inline([string]$s) {
    $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    $parts = $s -split '`'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i % 2) { $parts[$i] = '<code>' + $parts[$i] + '</code>' }
        else { $parts[$i] = $parts[$i] -replace '\*\*(.+?)\*\*', '<b>$1</b>' -replace '\*(.+?)\*', '<i>$1</i>' }
    }
    $parts -join ''
}
function Get-Id([string]$s) { ($s.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }
$lists = New-Object Collections.Stack; $code = $false; $table = 0; $para = @()
function Close-Para { if ($script:para.Count) { Add-Line ('<p>' + (Get-Inline ($script:para -join ' ')) + '</p>'); $script:para = @() } }
function Close-Lists { while ($lists.Count) { Add-Line "</li></$($lists.Pop())>" } }
foreach ($l in $lines) {
    if ($code) {
        if ($l.StartsWith('```')) { $code = $false; Add-Line '</pre>' } else { [void]$out.Append($l.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')).Append("`n") }
        continue
    }
    if ($table -and -not $l.StartsWith('|')) { Add-Line '</table></div>'; $table = 0 }
    if ($l.StartsWith('```')) {
        Close-Para; Close-Lists
        $where = if ($l -match 'powershell') { 'On your PC (PowerShell)' } else { 'On the server' }
        [void]$out.Append("<pre><span>$where</span>"); $code = $true
    }
    elseif ($l -match '^(#+) (.*)') {
        Close-Para; Close-Lists
        $h = $Matches[1].Length; $t = $Matches[2]; $id = Get-Id $t
        Add-Line "<h$h id=`"$id`">$(Get-Inline $t)</h$h>"
        if ($h -eq 2) { [void]$toc.Append("<a href=`"#$id`">$(Get-Inline $t)</a>`n") }
    }
    elseif ($l -match '^!\[(.*)\]\((.*)\)$') {
        Close-Para; Close-Lists
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$PSScriptRoot\$($Matches[2])"))
        Add-Line "<figure><img alt=`"$($Matches[1])`" src=`"data:image/png;base64,$b64`"><figcaption>$($Matches[1])</figcaption></figure>"
    }
    elseif ($l.StartsWith('|')) {
        Close-Para; Close-Lists
        if ($l -match '^\|[-| ]+\|$') { continue }
        $cells = $l.Trim().Trim('|') -split '\|'
        $tag = if ($table) { 'td' } else { Add-Line '<div class="t"><table>'; 'th' }
        $table++
        Add-Line ('<tr>' + (($cells | ForEach-Object { "<$tag>$(Get-Inline $_.Trim())</$tag>" }) -join '') + '</tr>')
    }
    elseif ($l -match '^( *)(\d+)\. (.*)') {
        Close-Para; $n = [int]$Matches[2]; $t = $Matches[3]
        if ($lists.Count) { Add-Line '</li>' } else { Add-Line "<ol start=`"$n`">"; $lists.Push('ol') }
        [void]$out.Append('<li>' + (Get-Inline $t))
    }
    elseif ($l -match '^( *)- (.*)') {
        Close-Para; $t = $Matches[2]; $deep = $Matches[1].Length -gt 0
        $want = if ($deep) { 2 } else { 1 }
        if ($lists.Count -lt $want) { Add-Line '<ul>'; $lists.Push('ul') }
        else { while ($lists.Count -gt $want) { Add-Line "</li></$($lists.Pop())>" }; Add-Line '</li>' }
        [void]$out.Append('<li>' + (Get-Inline $t))
    }
    elseif ($l.Trim().Length -eq 0) { Close-Para; Close-Lists }
    else { Close-Lists; $para += $l.Trim() }
}
Close-Para; Close-Lists
if ($table) { Add-Line '</table></div>' }
$css = @'
:root{--ink:#14192b;--mute:#5b6478;--line:#dfe3ec;--soft:#f3f5fa;--accent:#4b4fd6}
*{box-sizing:border-box}html{scroll-behavior:smooth}
body{margin:0;font:18px/1.65 Cambria,Georgia,serif;color:var(--ink);background:#fff}
nav{position:fixed;inset:0 auto 0 0;width:300px;overflow:auto;padding:28px 12px;background:#0b1220}
nav a{display:block;padding:6px 14px;border-radius:8px;color:#c9d2e3;text-decoration:none;font-size:15.5px;line-height:1.4}
nav a:hover,nav a:focus{background:#1b2640;color:#fff}
main{margin-left:300px;padding:40px 48px 120px;max-width:1020px}
h1{font-size:38px;line-height:1.2;margin:0 0 16px}h2{font-size:27px;line-height:1.3;margin:64px 0 14px;padding-top:22px;border-top:1px solid var(--line)}h3{font-size:21px;margin:34px 0 8px}
p{margin:12px 0}ol,ul{padding-left:30px;margin:12px 0}li{margin:6px 0}
code{font:.86em Consolas,"Cascadia Mono",monospace;background:var(--soft);padding:2px 6px;border-radius:5px;overflow-wrap:anywhere}
pre{position:relative;background:#0b1220;color:#e7ecf6;font:15px/1.6 Consolas,"Cascadia Mono",monospace;padding:38px 18px 16px;border-radius:10px;overflow-x:auto;margin:14px 0}
pre span{position:absolute;top:9px;left:18px;color:#8fa0c0;font:13.5px Cambria,Georgia,serif}
.t{overflow-x:auto;margin:16px 0}table{border-collapse:collapse;width:100%}th,td{text-align:left;vertical-align:top;padding:9px 14px 9px 0;border-bottom:1px solid var(--line)}th{color:var(--mute);font-size:16px}
figure{margin:20px 0}img{display:block;width:100%;border:1px solid var(--line);border-radius:10px}figcaption{color:var(--mute);font-size:15.5px;margin-top:6px}
@media(max-width:900px){nav{position:static;width:auto}main{margin:0;padding:24px 20px 80px}}
@media print{nav{display:none}main{margin:0;padding:0;max-width:none}body{font-size:12pt}pre{background:#fff;color:#000;border:1px solid #999;white-space:pre-wrap}pre span{color:#444}h2{break-after:avoid}figure,pre,tr{break-inside:avoid}}
'@
$html = "<!DOCTYPE html>`n<html lang=`"en`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width,initial-scale=1`"><title>ScriptIX, step by step</title><style>`n$css`n</style></head><body>`n<nav>`n$toc</nav>`n<main>`n$out</main></body></html>`n"
[IO.File]::WriteAllText("$PSScriptRoot\guide.html", $html.Replace("`r`n", "`n"), $u8)
