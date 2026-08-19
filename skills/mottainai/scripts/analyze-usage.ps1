<#
  analyze-usage.ps1 - the counting half of the "mottainai" skill (Windows).

  Reads Claude Code transcripts and prints a compact set of signals. Counting is
  mechanical, so it happens here, for free. Reading the signals is the agent's job.

  Runs on Windows PowerShell 5.1 with no modules and no installs. Lines are
  scanned with regexes rather than ConvertFrom-Json, which is what keeps a
  60 MB transcript folder to a few seconds instead of several minutes.

  This file is deliberately pure ASCII. Windows PowerShell 5.1 reads .ps1 as the
  system codepage unless the file carries a BOM, so translated text lives in
  ..\reference\labels.tsv and is read from there as UTF-8.

  Privacy: conversation text is never read out. Only timestamps, token counts,
  model names, tool names and session titles are touched, and nothing leaves
  this machine.

  Usage:
    .\analyze-usage.ps1                 # current 5-hour block + last 7 days
    .\analyze-usage.ps1 -Days 30        # widen the long window
    .\analyze-usage.ps1 -Lang ja        # en | ja | ko
#>

[CmdletBinding()]
param(
  [int]$Days = 7,
  [ValidateSet('en', 'ja', 'ko')][string]$Lang = 'en',
  [string]$ProjectsDir
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$refDir = Join-Path $PSScriptRoot '..\reference'

# ---------------------------------------------------------------- labels
$col = @{ en = 1; ja = 2; ko = 3 }[$Lang]
$L = @{}
$labelFile = Join-Path $refDir 'labels.tsv'
if (Test-Path $labelFile) {
  foreach ($ln in [System.IO.File]::ReadLines($labelFile, [System.Text.Encoding]::UTF8)) {
    if ($ln -match '^\s*#' -or -not $ln.Contains("`t")) { continue }
    $p = $ln.Split("`t")
    if ($p.Count -gt $col) { $L[$p[0]] = $p[$col] }
  }
}
function Say($key, $fallback) { if ($L.ContainsKey($key)) { $L[$key] } else { $fallback } }

# ---------------------------------------------------------------- prices
# Structural multipliers: how caching is billed relative to plain input. These
# are far more stable than per-model dollar figures, so they live in code.
$M_INPUT = 1.0; $M_WRITE = 1.25; $M_READ = 0.1

$price = @{ opus = @(5.0, 25.0); sonnet = @(3.0, 15.0); haiku = @(1.0, 5.0)
            fable = @(10.0, 50.0); other = @(3.0, 15.0) }
$priceAgeDays = -1
$tsv = Join-Path $refDir 'prices.tsv'
if (Test-Path $tsv) {
  foreach ($ln in [System.IO.File]::ReadLines($tsv)) {
    if ($ln -match '^#\s*UPDATED:\s*(\d{4}-\d{2}-\d{2})') {
      $priceAgeDays = [int]((Get-Date) - [datetime]$Matches[1]).TotalDays
    }
    elseif ($ln -notmatch '^\s*#' -and $ln -match '^(\S+)\s+([0-9.]+)\s+([0-9.]+)') {
      $price[$Matches[1]] = @([double]$Matches[2], [double]$Matches[3])
    }
  }
}

# ---------------------------------------------------------------- locate logs
if (-not $ProjectsDir) {
  if ($env:CLAUDE_PROJECTS_DIR) { $ProjectsDir = $env:CLAUDE_PROJECTS_DIR }
  else { $ProjectsDir = Join-Path $env:USERPROFILE '.claude\projects' }
}
if (-not (Test-Path $ProjectsDir)) { Write-Output ((Say 'none' 'No transcripts found at: ') + $ProjectsDir); exit 0 }
$files = @(Get-ChildItem -Path $ProjectsDir -Filter *.jsonl -Recurse -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) { Write-Output ((Say 'none' 'No transcripts found at: ') + $ProjectsDir); exit 0 }

$now = Get-Date
$weekCut = $now.AddDays(-$Days)

# ---------------------------------------------------------------- scan
$opt = [System.Text.RegularExpressions.RegexOptions]::Compiled
$reTs    = New-Object regex '"timestamp":"([^"]+)"', $opt
$reIn    = New-Object regex '"input_tokens":([0-9]+)', $opt
$reWr    = New-Object regex '"cache_creation_input_tokens":([0-9]+)', $opt
$reRd    = New-Object regex '"cache_read_input_tokens":([0-9]+)', $opt
$reOut   = New-Object regex '"output_tokens":([0-9]+)', $opt
$reTh    = New-Object regex '"thinking_tokens":([0-9]+)', $opt
$reModel = New-Object regex '"model":"([^"]+)"', $opt
$reMsgId = New-Object regex '"id":"(msg_[^"]+)"', $opt
$reTool  = New-Object regex '"type":"tool_use","id":"[^"]*","name":"([^"]+)"', $opt
$reTitle = New-Object regex '"(?:customTitle|aiTitle)":"([^"]+)"', $opt

function Num($re, $s) { $m = $re.Match($s); if ($m.Success) { [double]$m.Groups[1].Value } else { 0.0 } }

$events = New-Object System.Collections.ArrayList
$titles = @{}

foreach ($f in $files) {
  if ($f.Length -lt 200 -or $f.LastWriteTime -lt $weekCut) { continue }
  $sid = $f.BaseName
  $seen = @{}
  foreach ($line in [System.IO.File]::ReadLines($f.FullName, [System.Text.Encoding]::UTF8)) {
    if ($line.Length -lt 20) { continue }

    if (-not $titles.ContainsKey($sid)) {
      $mt = $reTitle.Match($line)
      if ($mt.Success) { $titles[$sid] = $mt.Groups[1].Value }
    }

    $hasUsage = $line.Contains('"usage":{')
    $isResult = (-not $hasUsage) -and $line.Contains('"tool_result"')
    $isTurn = (-not $hasUsage) -and (-not $isResult) -and $line.Contains('"type":"user"') -and
              (-not $line.Contains('"isMeta":true'))
    # Failed tool results live on their own lines, separate from any usage block.
    $isFail = $isResult -and $line.Contains('"is_error":true')
    if (-not $hasUsage -and -not $isTurn -and -not $isFail) { continue }

    $mTs = $reTs.Match($line); if (-not $mTs.Success) { continue }
    $ts = [datetime]::MinValue
    if (-not [datetime]::TryParse($mTs.Groups[1].Value, [ref]$ts)) { continue }
    if ($ts -lt $weekCut) { continue }

    if ($isTurn -or $isFail) {
      [void]$events.Add([pscustomobject]@{ Ts = $ts; Sid = $sid; Turn = [int]$isTurn; In = 0.0
        Wr = 0.0; Rd = 0.0; Out = 0.0; Th = 0.0; Fam = 'other'; Tools = ''
        Err = [int]$isFail; Side = 0; Sched = 0 })
      continue
    }

    # A streamed assistant message repeats across lines; count it once.
    $mId = $reMsgId.Match($line)
    if ($mId.Success) {
      $key = $mId.Groups[1].Value
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = $true
    }

    $fam = 'other'
    $mm = $reModel.Match($line)
    if ($mm.Success) {
      $mv = $mm.Groups[1].Value
      if ($mv -like '*opus*') { $fam = 'opus' }
      elseif ($mv -like '*sonnet*') { $fam = 'sonnet' }
      elseif ($mv -like '*haiku*') { $fam = 'haiku' }
      elseif ($mv -like '*fable*') { $fam = 'fable' }
    }

    $tools = ''
    $tm = $reTool.Matches($line)
    if ($tm.Count -gt 0) { $tools = (($tm | ForEach-Object { $_.Groups[1].Value }) -join ',') }

    [void]$events.Add([pscustomobject]@{
      Ts = $ts; Sid = $sid; Turn = 0
      In = (Num $reIn $line); Wr = (Num $reWr $line); Rd = (Num $reRd $line)
      Out = (Num $reOut $line); Th = (Num $reTh $line)
      Fam = $fam; Tools = $tools
      Err = [int]$line.Contains('"is_error":true')
      Side = [int]$line.Contains('"isSidechain":true')
      Sched = [int]$line.Contains('<scheduled-task name=')
    })
  }
}

if ($events.Count -eq 0) { Write-Output ((Say 'none' 'No transcripts found at: ') + $ProjectsDir); exit 0 }
$events = @($events | Sort-Object Ts)

# The real limit is a rolling window opened by the first prompt after a quiet
# spell, so the block starts at the first event following a gap of 5h or more.
$blockStart = $events[0].Ts
$prev = $null
foreach ($e in $events) {
  if ($null -ne $prev -and ($e.Ts - $prev).TotalHours -ge 5) { $blockStart = $e.Ts }
  $prev = $e.Ts
}

# ---------------------------------------------------------------- helpers
function Pct($a, $b) { if ($b -le 0) { 0 } else { [math]::Round(100 * $a / $b) } }
function Fmt($n) {
  if ($n -ge 1e6) { '{0:N1}M' -f ($n / 1e6) }
  elseif ($n -ge 1e3) { '{0:N0}k' -f ($n / 1e3) }
  else { '{0:N0}' -f $n }
}

function Report($set, $heading) {
  Write-Output ''
  Write-Output "## $heading"
  $set = @($set)
  if ($set.Count -eq 0) { Write-Output (Say 'empty' '(no activity in this window)'); return }

  $wRd = 0.0; $wFr = 0.0; $wOut = 0.0
  $rRd = 0.0; $rFr = 0.0; $rOut = 0.0; $rTh = 0.0
  $turns = 0; $errs = 0; $calls = 0; $wSide = 0.0; $wSched = 0.0
  $byModel = @{}; $byTool = @{}; $sess = @{}

  foreach ($e in $set) {
    if (-not $sess.ContainsKey($e.Sid)) {
      $sess[$e.Sid] = [pscustomobject]@{ W = 0.0; Rd = 0.0; Turns = 0; Fams = @{} }
    }
    $s = $sess[$e.Sid]
    if ($e.Turn) { $turns++; $s.Turns++; continue }

    $p = $price[$e.Fam]; if (-not $p) { $p = $price['other'] }
    $wR = $e.Rd * $M_READ * $p[0] / 1e6
    $wF = ($e.In * $M_INPUT + $e.Wr * $M_WRITE) * $p[0] / 1e6
    $wO = $e.Out * $p[1] / 1e6
    $w = $wR + $wF + $wO

    $wRd += $wR; $wFr += $wF; $wOut += $wO
    $rRd += $e.Rd; $rFr += $e.In + $e.Wr; $rOut += $e.Out; $rTh += $e.Th
    $errs += $e.Err
    if ($e.Side) { $wSide += $w }
    if ($e.Sched) { $wSched += $w }

    $byModel[$e.Fam] = [double]$byModel[$e.Fam] + $w
    $s.W += $w; $s.Rd += $wR; $s.Fams[$e.Fam] = $true

    if ($e.Tools) {
      foreach ($t in $e.Tools.Split(',')) {
        if ($t) { $byTool[$t] = [int]$byTool[$t] + 1; $calls++ }
      }
    }
  }

  $wTot = $wRd + $wFr + $wOut
  $rTot = $rRd + $rFr + $rOut
  if ($wTot -le 0) { Write-Output (Say 'empty' '(no activity in this window)'); return }

  Write-Output ("weighted: {0}% {1} / {2}% {3} / {4}% {5}" -f `
    (Pct $wRd $wTot), (Say 'reread' 're-reading'), (Pct $wFr $wTot), (Say 'fresh' 'new content'),
    (Pct $wOut $wTot), (Say 'reply' 'replies'))
  Write-Output ("raw tokens: {0} total ({1} reread / {2} new / {3} out)" -f `
    (Fmt $rTot), (Fmt $rRd), (Fmt $rFr), (Fmt $rOut))

  $mparts = @()
  foreach ($k in ($byModel.Keys | Sort-Object { -$byModel[$_] })) {
    $mparts += ("{0} {1}%" -f $k, (Pct $byModel[$k] $wTot))
  }
  Write-Output ("models: " + ($mparts -join ' / '))

  Write-Output ''
  Write-Output ("### " + (Say 'sessions' 'Heaviest sessions'))
  foreach ($kv in ($sess.GetEnumerator() | Sort-Object { -$_.Value.W } | Select-Object -First 5)) {
    $s = $kv.Value
    if ($s.W -le 0) { continue }
    $t = $titles[$kv.Key]; if (-not $t) { $t = '(untitled)' }
    if ($t.Length -gt 34) { $t = $t.Substring(0, 34) }
    Write-Output ("- {0}% | turns {1} | reread {2}% | {3} | {4}" -f `
      (Pct $s.W $wTot), $s.Turns, (Pct $s.Rd $s.W), (($s.Fams.Keys | Sort-Object) -join '+'), $t)
  }

  Write-Output ''
  Write-Output ("### " + (Say 'signals' 'Signals'))
  Write-Output ("- {0}: {1} across {2} sessions" -f (Say 'turns' 'user turns'), $turns, $sess.Count)
  Write-Output ("- tool calls: {0}, {1}: {2} ({3}%)" -f `
    $calls, (Say 'failed' 'failed tool results'), $errs, (Pct $errs $calls))
  Write-Output ("- {0}: {1}%" -f (Say 'thinking' 'thinking share of replies'), (Pct $rTh $rOut))
  Write-Output ("- {0}: {1}%   {2}: {3}%" -f `
    (Say 'subagent' 'subagent share'), (Pct $wSide $wTot),
    (Say 'scheduled' 'scheduled-task share'), (Pct $wSched $wTot))

  $tparts = @()
  foreach ($kv in ($byTool.GetEnumerator() | Sort-Object { -$_.Value } | Select-Object -First 6)) {
    $tparts += ("{0}x{1}" -f $kv.Key, $kv.Value)
  }
  if ($tparts.Count) { Write-Output ("- " + (Say 'tools' 'top tools') + ": " + ($tparts -join ', ')) }

  # Few turns but heavy: the signature of a big load-in early in a session.
  $heavy = @()
  foreach ($kv in $sess.GetEnumerator()) {
    if ($kv.Value.Turns -le 15 -and (Pct $kv.Value.W $wTot) -ge 15) {
      $t = $titles[$kv.Key]; if (-not $t) { $t = '(untitled)' }
      $heavy += ("{0} ({1} turns, {2}%)" -f $t, $kv.Value.Turns, (Pct $kv.Value.W $wTot))
    }
  }
  if ($heavy.Count) { Write-Output ("- " + (Say 'fewturns' 'few turns but heavy') + ": " + ($heavy -join '; ')) }
}

# ---------------------------------------------------------------- emit
Write-Output '# mottainai raw signals'
Write-Output 'weighted = cost-weighted share (read 0.1x, write 1.25x, reply 5x, per model price).'
Write-Output 'Claude Code transcripts only; claude.ai and the desktop app are not visible here.'
if ($priceAgeDays -ge 90) {
  Write-Output ('! ' + ((Say 'stale' 'PRICE TABLE IS {0} DAYS OLD') -f $priceAgeDays))
}

Report ($events | Where-Object { $_.Ts -ge $blockStart }) `
  ((Say 'block' 'CURRENT 5-HOUR BLOCK') + ' (' + (Say 'began' 'block began') + ' ' +
   $blockStart.ToString('yyyy-MM-dd HH:mm') + ')')
Report $events ((Say 'week' 'LAST {0} DAYS') -f $Days)
