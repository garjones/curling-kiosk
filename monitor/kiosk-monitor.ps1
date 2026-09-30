#!/usr/bin/env pwsh
# --------------------------------------------------------------------------------
#  kiosk-monitor.ps1
#
#  Polls all Raspberry Pis and cameras every 30 seconds and writes a
#  self-contained kiosk-monitor.html with status data embedded directly.
#  Open kiosk-monitor.html in any browser -- no server required.
#
#  Run this script once -- it loops indefinitely until closed.
#
#  Requirements:
#    - PowerShell 7 or later (cross-platform: Windows, macOS, Linux)
#    - ssh (built-in on macOS/Linux; included with Windows 10/11)
#    - sshpass (macOS/Linux only -- install via: brew install sshpass)
#    - curl (built-in on macOS/Linux and Windows 10/11)
#    - pi-hosts.txt -- Pi IP addresses and hostnames
#    - kiosk.env    -- camera credentials and IPs
#
#  Version 5.5
# --------------------------------------------------------------------------------
#  (C) Copyright Gareth Jones - gareth@gareth.com
# --------------------------------------------------------------------------------

$SCRIPT_DIR  = Split-Path -Parent $MyInvocation.MyCommand.Path
$HOSTS_FILE  = Join-Path $SCRIPT_DIR "pi-hosts.txt"
$ENV_FILE    = Join-Path $SCRIPT_DIR "kiosk.env"
$HTML_FILE   = Join-Path $SCRIPT_DIR "kiosk-monitor.html"
$SSH_USER    = "kcckiosk"
$SSH_PASS    = "CHANGEME"   # set per site; do not commit real value
$SSH_PORT    = 22
$RTSP_PORT   = 554
$POLL_SECS   = 30
$HTTP_PORT   = 8080

# detect platform and locate SSH tools
$IS_WINDOWS = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

function Find-Tool($name) {
    $inPath = Get-Command $name -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    # check common Homebrew locations (macOS) when not on PATH
    foreach ($prefix in @("/opt/homebrew/bin", "/usr/local/bin")) {
        $candidate = Join-Path $prefix $name
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

$SSH     = Find-Tool "ssh"
$SSHPASS = Find-Tool "sshpass"   # macOS/Linux only; install via: brew install sshpass
$CURL    = Find-Tool "curl"
$FFPLAY  = Find-Tool "ffplay"

# --------------------------------------------------------------------------------
# load pi-hosts.txt
# --------------------------------------------------------------------------------
function Load-Hosts {
    if (-not (Test-Path $HOSTS_FILE)) { return @() }
    $hosts = @()
    foreach ($line in Get-Content $HOSTS_FILE) {
        $line = $line.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        $parts = $line -split '\s+'
        if ($parts.Count -ge 2) {
            $hosts += [PSCustomObject]@{ IP = $parts[0]; Name = $parts[1] }
        }
    }
    return $hosts
}

# --------------------------------------------------------------------------------
# load kiosk.env
# --------------------------------------------------------------------------------
function Load-Env {
    $env = @{ CAM_USER = ""; CAM_PASS = ""; CAM_HOME = @(); CAM_AWAY = @() }
    if (-not (Test-Path $ENV_FILE)) { return $env }
    $homeList = @(); $awayList = @()
    $inHome = $false; $inAway = $false
    foreach ($line in Get-Content $ENV_FILE) {
        $line = $line.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        if ($line -match '^CAM_USER="?([^"]*)"?') { $env.CAM_USER = $Matches[1]; continue }
        if ($line -match '^CAM_PASS="?([^"]*)"?') { $env.CAM_PASS = $Matches[1]; continue }
        if ($line -match '^CAM_HOME=\(') { $inHome = $true;  $inAway = $false; continue }
        if ($line -match '^CAM_AWAY=\(') { $inAway = $true;  $inHome = $false; continue }
        if ($inHome -or $inAway) {
            if ($line -eq ")") { $inHome = $false; $inAway = $false; continue }
            $ip = $line -replace '"','' -replace "'",''
            if ($ip -ne "") {
                if ($inHome) { $homeList += $ip } else { $awayList += $ip }
            }
        }
    }
    $env.CAM_HOME = $homeList
    $env.CAM_AWAY = $awayList
    return $env
}

# --------------------------------------------------------------------------------
# checks
# --------------------------------------------------------------------------------
function Test-Ping($ip) {
    try {
        if ($script:IS_WINDOWS) {
            return (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue)
        } else {
            & ping -c 1 -W 2 $ip 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
    } catch { return $false }
}

function Test-TcpPort($ip, $port) {
    try {
        $tcp  = New-Object System.Net.Sockets.TcpClient
        $conn = $tcp.BeginConnect($ip, $port, $null, $null)
        $wait = $conn.AsyncWaitHandle.WaitOne(2000, $false)
        if ($wait) { $tcp.EndConnect($conn); $tcp.Close(); return $true }
        $tcp.Close(); return $false
    } catch { return $false }
}

function Invoke-SSH($ip, $command) {
    if (-not $script:SSH) { return "unknown" }
    try {
        $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5", "-p", $script:SSH_PORT, "$($script:SSH_USER)@${ip}")
        if ($script:IS_WINDOWS) {
            $out = & $script:SSH @sshOpts $command 2>&1
        } else {
            if (-not $script:SSHPASS) { return "unknown" }
            $out = & $script:SSHPASS -p $script:SSH_PASS $script:SSH @sshOpts $command 2>&1
        }
        return ($out -join "").Trim()
    } catch { return "" }
}

function Test-KioskService($ip) {
    $text = Invoke-SSH $ip "systemctl is-active kiosk.service"
    if ($text -eq "active")   { return "active" }
    if ($text -eq "inactive") { return "inactive" }
    if ($text -eq "failed")   { return "failed" }
    return "unknown"
}

function Get-KioskConfig($ip) {
    $text = Invoke-SSH $ip "cat /home/kcckiosk/kiosk.config 2>/dev/null"
    return $text.Trim()
}

function Set-KioskConfig($ip, $config) {
    $result = Invoke-SSH $ip "echo '$config' > /home/kcckiosk/kiosk.config && sudo sync && sudo reboot"
    # reboot closes the SSH session so any output or error is expected
    return $true
}

# --------------------------------------------------------------------------------
# decode a raw config code (e.g. "HC0102") into a human-readable label
# --------------------------------------------------------------------------------
function ConvertTo-ConfigLabel($config) {
    if ($config -eq "" -or $config.Length -lt 2) { return "Unknown" }

    $rotation = $config.Substring(0, 1)
    $mode     = $config.Substring(1, 1)

    $rotLabel = switch ($rotation) {
        "H" { "Horizontal" }
        "V" { "Vertical" }
        default { "?" }
    }

    switch ($mode) {
        "C" {
            if ($config.Length -ge 6) {
                $bot = [int]$config.Substring(2, 2)
                $top = [int]$config.Substring(4, 2)
                return "$rotLabel · Cameras · Sheets $bot & $top"
            }
        }
        "S" {
            if ($config.Length -ge 4) {
                $sheet = [int]$config.Substring(2, 2)
                return "$rotLabel · Single Camera · Sheet $sheet"
            }
        }
        "K" {
            if ($config.Length -ge 4) {
                $chan = [int]$config.Substring(2, 2)
                $loc  = switch ($chan) { 1 { "Upstairs" } 2 { "Practice Ice" } default { "Channel $chan" } }
                return "$rotLabel · Kiosk · $loc"
            }
        }
    }
    return $config
}

# --------------------------------------------------------------------------------
# fetch camera snapshot as base64
# Returns a base64 string on success, or empty string on failure
# --------------------------------------------------------------------------------
function Get-CameraSnapshot($ip, $user, $pass) {
    try {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        & curl --digest --user "${user}:${pass}" "http://${ip}/axis-cgi/jpg/image.cgi" `
               -o $tmpFile --silent --max-time 5 2>$null
        if (Test-Path $tmpFile) {
            $bytes = [System.IO.File]::ReadAllBytes($tmpFile)
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            if ($bytes.Length -gt 0) {
                return [Convert]::ToBase64String($bytes)
            }
        }
    } catch { }
    return ""
}

# --------------------------------------------------------------------------------
# write self-contained HTML dashboard
# --------------------------------------------------------------------------------
function Write-Dashboard($timestamp, $piResults, $camResults, $camUser, $camPass) {

    # read current pi-hosts.txt for the editor
    # ConvertTo-Json produces a properly-escaped JSON string literal (including newlines,
    # backslashes, quotes) — strip the surrounding outer quotes so it embeds cleanly as a JS value
    $hostsContentJson = ""
    if (Test-Path $HOSTS_FILE) {
        $hostsRaw = Get-Content $HOSTS_FILE -Raw
        if ($hostsRaw -eq $null) { $hostsRaw = "" }
        $hostsContentJson = ($hostsRaw | ConvertTo-Json)
    } else {
        $hostsContentJson = '""'
    }

    # build Pi cards HTML
    $piCards = ""
    foreach ($pi in $piResults) {
        $cardClass   = if (-not $pi.ping) { "offline" } elseif ($pi.service -ne "active") { "degraded" } else { "all-ok" }
        $pingDot     = if ($pi.ping) { '<span class="dot ok"></span>' }  else { '<span class="dot fail"></span>' }
        $sshDot      = if ($pi.ssh)  { '<span class="dot ok"></span>' }  else { '<span class="dot fail"></span>' }
        $svcClass    = switch ($pi.service) { "active" {"active"} "inactive" {"inactive"} "failed" {"failed"} default {"unknown"} }
        $configLabel = if ($pi.config -ne "") { ConvertTo-ConfigLabel $pi.config } else { "" }
        $configHtml  = if ($configLabel -ne "") {
            "<div class=`"pi-config`"><span class=`"pi-config-code`">$($pi.config)</span> $configLabel</div>"
        } else { "" }
        $uptimeHtml = if ($pi.uptime -ne "" -and $pi.uptime -ne $null) {
            "<div class=`"pi-meta`">&#9201; $($pi.uptime)</div>"
        } else { "" }
        $resHtml = if ($pi.resolution -ne "" -and $pi.resolution -ne $null) {
            "<div class=`"pi-meta`">&#9974; $($pi.resolution)</div>"
        } else { "" }
        $lastSeenHtml = if ($pi.lastSeen -ne "" -and $pi.lastSeen -ne $null) {
            "<div class=`"last-seen`">Last seen: $($pi.lastSeen)</div>"
        } else { "" }
        $piCards += @"
        <div class="pi-card $cardClass" onclick="openConfigPanel('$($pi.name)','$($pi.ip)','$($pi.config)','$($pi.resolution)')" title="Click to configure">
          <div class="pi-name">$($pi.name)</div>
          <div class="pi-ip">$($pi.ip)</div>
          <div class="pi-checks">
            <div class="check-badge">$pingDot Ping</div>
            <div class="check-badge">$sshDot SSH</div>
            <div class="check-badge"><span class="svc-badge svc-$svcClass">$($pi.service)</span></div>
          </div>
          $configHtml
          $uptimeHtml
          $resHtml
          $lastSeenHtml
        </div>
"@
    }

    # build camera grid HTML
    # index camResults by sheet + end
    $bySheet = @{}
    foreach ($c in $camResults) {
        if (-not $bySheet.ContainsKey($c.sheet)) { $bySheet[$c.sheet] = @{} }
        $bySheet[$c.sheet][$c.end] = $c
    }

    # column headers  (sheet numbers 1-12)
    $colHeaders = ""
    for ($s = 1; $s -le 12; $s++) {
        $colHeaders += "      <div class=`"cam-col-header`">$s</div>`n"
    }

    # helper: build one row of 12 camera cells
    function Build-CamRow($endLabel, $bySheet) {
        $row = "    <div class=`"cam-row`">`n"
        $row += "      <div class=`"cam-row-label`">$endLabel</div>`n"
        for ($s = 1; $s -le 12; $s++) {
            $cam = if ($bySheet.ContainsKey($s)) { $bySheet[$s][$endLabel] } else { $null }
            if ($cam) {
                $cls    = if ($cam.up) { "up" } else { "down" }
                $stat   = if ($cam.up) { "UP" } else { "DOWN" }
                $lastSeenCamHtml = if (-not $cam.up -and $cam.lastSeen -ne "" -and $cam.lastSeen -ne $null) {
                    "<div class=`"cam-last-seen`">$($cam.lastSeen)</div>"
                } else { "" }
                $imgTag = if ($cam.snapshot -ne "") {
                    "<div class=`"cam-thumb-wrap`"><img class=`"cam-thumb`" src=`"data:image/jpeg;base64,$($cam.snapshot)`" alt=`"Sheet $s $endLabel`"></div>"
                } else {
                    "<div class=`"cam-thumb-wrap cam-no-image`">No image</div>"
                }
                $row += @"
      <div class="cam-cell $cls">
        <div class="cam-info">
          <span class="cam-ip">$($cam.ip)</span>
          <span class="cam-status $cls">$stat</span>
        </div>
        $lastSeenCamHtml
        $imgTag
      </div>
"@
            } else {
                $row += "      <div class=`"cam-cell`"><div class=`"cam-thumb cam-no-image`">—</div></div>`n"
            }
        }
        $row += "    </div>`n"
        return $row
    }

    $awayRow = Build-CamRow "Away" $bySheet
    $homeRow = Build-CamRow "Home" $bySheet

    # summary counts
    $pisTotal  = $piResults.Count
    $pisOk     = ($piResults | Where-Object { $_.ping -and $_.ssh }).Count
    $pisFail   = $pisTotal - $pisOk
    $svcActive = ($piResults | Where-Object { $_.service -eq "active" }).Count
    $camsTotal = $camResults.Count
    $camsUp    = ($camResults | Where-Object { $_.up }).Count
    $camsFail  = $camsTotal - $camsUp

    $piSumClass  = if ($pisFail  -eq 0) { "ok" } else { "fail" }
    $svcSumClass = if ($svcActive -eq $pisTotal) { "ok" } else { "warn" }
    $camSumClass = if ($camsFail  -eq 0) { "ok" } else { "fail" }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>KCC Pi Kiosk -- Status Dashboard</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }

    /* ---- theme variables ---- */
    :root {
      --bg:          #0f1923;
      --bg-card:     #1a2535;
      --bg-header:   #1a2a3a;
      --bg-dark:     #121c28;
      --bg-input:    #1a2535;
      --border:      #253545;
      --border-2:    #2a3a4a;
      --accent:      #1e5fa8;
      --accent-2:    #2a7ad8;
      --text:        #e0e0e0;
      --text-sub:    #7a9ab8;
      --text-dim:    #5a7a9a;
      --text-mono:   #6a8aaa;
      --text-blue:   #5b9bd5;
      --ok:          #27ae60;
      --warn:        #e67e22;
      --fail:        #c0392b;
    }
    body.light {
      --bg:          #f0f4f8;
      --bg-card:     #ffffff;
      --bg-header:   #1a2a3a;
      --bg-dark:     #e2e8f0;
      --bg-input:    #f8fafc;
      --border:      #cbd5e0;
      --border-2:    #a0aec0;
      --text:        #1a202c;
      --text-sub:    #4a5568;
      --text-dim:    #718096;
      --text-mono:   #2d3748;
      --text-blue:   #2b6cb0;
    }

    body { font-family: 'Segoe UI', Arial, sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; padding: 0 0 32px 0; transition: background 0.2s, color 0.2s; }

    /* ---- header ---- */
    header { background: var(--bg-header); border-bottom: 3px solid var(--accent); padding: 16px 28px; display: flex; align-items: center; justify-content: space-between; }
    header h1 { font-size: 1.3rem; font-weight: 600; color: #fff; }
    header h1 span { color: #5b9bd5; }
    .subtitle { font-size: 0.72rem; color: #5a7a9a; margin-top: 3px; }
    .updated { font-size: 0.78rem; color: var(--text-sub); text-align: right; }
    .refreshing { font-size: 0.78rem; color: var(--text-blue); margin-top: 2px; text-align: right; }
    .theme-btn {
      background: none; border: 1px solid #3a5a7a; border-radius: 4px;
      color: #7a9ab8; font-size: 0.78rem; padding: 4px 10px;
      cursor: pointer; margin-left: 12px; transition: all 0.15s;
    }
    .theme-btn:hover { border-color: #5b9bd5; color: #fff; }

    /* ---- section titles ---- */
    .section-title { font-size: 0.7rem; font-weight: 700; letter-spacing: 0.12em; text-transform: uppercase; color: #5b9bd5; padding: 22px 28px 10px; }

    /* ---- summary bar ---- */
    #summary-bar { display: flex; gap: 24px; padding: 14px 28px 0; flex-wrap: wrap; }
    .summary-item { display: flex; align-items: center; gap: 8px; }
    .summary-count { font-size: 1.6rem; font-weight: 700; line-height: 1; }
    .summary-count.ok   { color: #27ae60; }
    .summary-count.warn { color: #e67e22; }
    .summary-count.fail { color: #c0392b; }
    .summary-label { font-size: 0.7rem; color: #7a9ab8; line-height: 1.3; }

    /* ---- Pi grid ---- */
    #pi-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 10px; padding: 0 28px; }
    .pi-card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 6px; padding: 12px 14px; }
    .pi-card.all-ok   { border-left: 3px solid var(--ok); }
    .pi-card.degraded { border-left: 3px solid var(--warn); }
    .pi-card.offline  { border-left: 3px solid var(--fail); }
    .pi-name { font-size: 0.88rem; font-weight: 600; color: var(--text); margin-bottom: 2px; }
    .pi-ip   { font-size: 0.72rem; color: var(--text-mono); font-family: 'Consolas', monospace; margin-bottom: 10px; }
    .pi-checks { display: flex; gap: 8px; flex-wrap: wrap; }
    .check-badge { display: flex; align-items: center; gap: 4px; font-size: 0.7rem; color: #aaa; }
    .dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; display: inline-block; }
    .dot.ok   { background: #27ae60; }
    .dot.fail { background: #c0392b; }
    .svc-badge { font-size: 0.65rem; padding: 1px 5px; border-radius: 3px; font-weight: 600; text-transform: uppercase; }
    .svc-active   { background: #1a4a2a; color: #5dca80; }
    .svc-inactive { background: #3a2a10; color: #d4a04a; }
    .svc-failed   { background: #4a1a1a; color: #e07070; }
    .svc-unknown  { background: #2a2a2a; color: #888; }
    .pi-config { margin-top: 8px; font-size: 0.7rem; color: #7a9ab8; line-height: 1.4; }
    .pi-config-code { font-family: 'Consolas', monospace; font-size: 0.7rem; color: #5b9bd5; font-weight: 700; margin-right: 4px; }
    .pi-meta { margin-top: 4px; font-size: 0.68rem; color: #5a7a9a; }
    .last-seen { margin-top: 6px; font-size: 0.65rem; color: #c0392b; font-style: italic; }

    /* ---- Pi card clickable ---- */
    .pi-card { cursor: pointer; transition: border-color 0.15s, box-shadow 0.15s; }
    .pi-card:hover { box-shadow: 0 0 0 2px #2a6ab0; }

    /* ---- config panel ---- */
    #config-overlay {
      display: none;
      position: fixed;
      inset: 0;
      background: rgba(0,0,0,0.45);
      z-index: 100;
    }
    #config-overlay.open { display: block; }

    #config-panel {
      position: fixed;
      top: 0; right: 0;
      width: 360px;
      height: 100vh;
      background: #131f2e;
      border-left: 3px solid #1e5fa8;
      z-index: 101;
      display: flex;
      flex-direction: column;
      transform: translateX(100%);
      transition: transform 0.25s ease;
      overflow-y: auto;
    }
    #config-panel.open { transform: translateX(0); }

    .cp-header {
      background: #1a2a3a;
      padding: 16px 18px;
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      border-bottom: 1px solid #253545;
      flex-shrink: 0;
    }
    .cp-title { font-size: 1rem; font-weight: 600; color: #fff; }
    .cp-ip    { font-size: 0.72rem; color: #6a8aaa; font-family: 'Consolas', monospace; margin-top: 2px; }
    .cp-rename-icon {
      background: none; border: none; color: #3a6080; font-size: 0.85rem;
      cursor: pointer; padding: 0; line-height: 1; transition: color 0.15s;
    }
    .cp-rename-icon:hover { color: #5b9bd5; }
    .cp-rename-input {
      background: #0f1923; border: 1px solid #2a6ab0; border-radius: 3px;
      color: #fff; font-size: 0.95rem; font-weight: 600;
      padding: 2px 6px; width: 160px;
    }
    .cp-rename-input:focus { outline: none; border-color: #5b9bd5; }
    .cp-rename-confirm, .cp-rename-cancel {
      background: none; border: none; font-size: 1rem;
      cursor: pointer; padding: 0 2px; line-height: 1;
    }
    .cp-rename-confirm { color: #27ae60; }
    .cp-rename-confirm:hover { color: #5dca80; }
    .cp-rename-cancel  { color: #c0392b; }
    .cp-rename-cancel:hover  { color: #e07070; }
    .cp-close {
      background: none; border: none; color: #7a9ab8; font-size: 1.4rem;
      cursor: pointer; line-height: 1; padding: 0 0 0 12px; flex-shrink: 0;
    }
    .cp-close:hover { color: #fff; }

    .cp-body { padding: 20px 18px; flex: 1; }

    .cp-section { margin-bottom: 20px; }
    .cp-label {
      font-size: 0.65rem; font-weight: 700; letter-spacing: 0.1em;
      text-transform: uppercase; color: #3a6080; margin-bottom: 8px;
    }

    .toggle-group { display: flex; gap: 6px; flex-wrap: wrap; }
    .toggle-btn {
      background: #1a2535; border: 1px solid #2a3a4a; border-radius: 4px;
      color: #7a9ab8; font-size: 0.78rem; font-weight: 600; padding: 6px 14px;
      cursor: pointer; transition: all 0.15s;
    }
    .toggle-btn:hover  { border-color: #2a6ab0; color: #fff; }
    .toggle-btn.active { background: #1e5fa8; border-color: #2a7ad8; color: #fff; }

    .cp-select {
      width: 100%; background: #1a2535; border: 1px solid #2a3a4a;
      border-radius: 4px; color: #e0e0e0; font-size: 0.82rem;
      padding: 7px 10px; appearance: none;
    }
    .cp-select:focus { outline: none; border-color: #2a6ab0; }

    .cp-preview {
      background: #0f1923; border: 1px solid #253545; border-radius: 4px;
      padding: 10px 14px; margin-bottom: 20px; text-align: center;
    }
    .cp-preview-code {
      font-family: 'Consolas', monospace; font-size: 1.4rem;
      font-weight: 700; color: #5b9bd5; display: block;
    }
    .cp-preview-label { font-size: 0.72rem; color: #7a9ab8; margin-top: 4px; }

    .cp-footer { padding: 0 18px 20px; display: flex; gap: 10px; flex-shrink: 0; }
    .cp-apply {
      flex: 1; background: #1e5fa8; border: none; border-radius: 4px;
      color: #fff; font-size: 0.85rem; font-weight: 600; padding: 10px;
      cursor: pointer; transition: background 0.15s;
    }
    .cp-apply:hover    { background: #2a7ad8; }
    .cp-apply:disabled { background: #253545; color: #5a7a9a; cursor: not-allowed; }
    .cp-cancel {
      background: #1a2535; border: 1px solid #2a3a4a; border-radius: 4px;
      color: #7a9ab8; font-size: 0.85rem; padding: 10px 18px;
      cursor: pointer; transition: all 0.15s;
    }
    .cp-cancel:hover { border-color: #2a6ab0; color: #fff; }

    .cp-actions { padding: 0 18px 16px; display: flex; gap: 8px; flex-shrink: 0; }
    .cp-action-btn {
      flex: 1; background: #1a2535; border: 1px solid #2a3a4a; border-radius: 4px;
      color: #7a9ab8; font-size: 0.78rem; font-weight: 600; padding: 8px 10px;
      cursor: pointer; transition: all 0.15s; text-align: center;
    }
    .cp-action-btn:hover    { border-color: #2a6ab0; color: #fff; background: #1e3050; }
    .cp-action-btn:disabled { opacity: 0.4; cursor: not-allowed; }

    .cp-res-row { display: flex; gap: 8px; align-items: center; }
    .cp-res-apply {
      flex-shrink: 0; background: #1a3a28; border: 1px solid #27ae60; border-radius: 4px;
      color: #5dca80; font-size: 0.78rem; font-weight: 600; padding: 7px 12px;
      cursor: pointer; transition: all 0.15s; white-space: nowrap;
    }
    .cp-res-apply:hover    { background: #1e5a38; border-color: #5dca80; color: #fff; }
    .cp-res-apply:disabled { opacity: 0.4; cursor: not-allowed; }
    .cp-log {
      display: none;
      margin: 0 18px 16px;
      background: #0a1018;
      border: 1px solid #253545;
      border-radius: 4px;
      padding: 10px 12px;
      font-family: 'Consolas', monospace;
      font-size: 0.68rem;
      color: #8ab0c8;
      max-height: 200px;
      overflow-y: auto;
      white-space: pre-wrap;
      word-break: break-all;
      flex-shrink: 0;
    }
    .cp-log.visible { display: block; }

    .cp-message {
      margin: 0 18px 16px; padding: 10px 14px; border-radius: 4px;
      font-size: 0.8rem; display: none;
    }
    .cp-message.error   { background: #4a1a1a; border: 1px solid #c0392b; color: #e07070; display: block; }
    .cp-message.success { background: #1a4a2a; border: 1px solid #27ae60; color: #5dca80; display: block; }

    /* ---- global actions toolbar ---- */
    #global-toolbar {
      display: flex;
      gap: 8px;
      padding: 10px 28px;
      background: var(--bg-dark);
      border-bottom: 1px solid var(--border);
      flex-wrap: wrap;
    }
    .toolbar-btn {
      background: var(--bg-card); border: 1px solid var(--border-2); border-radius: 4px;
      color: var(--text-sub); font-size: 0.78rem; font-weight: 600;
      padding: 7px 16px; cursor: pointer; transition: all 0.15s;
    }
    .toolbar-btn:hover { border-color: var(--accent); color: var(--text); background: #1e3050; }
    .toolbar-btn.danger:hover { border-color: var(--fail); color: #e07070; background: #2a1a1a; }

    /* ---- progress modal ---- */
    #progress-overlay {
      display: none; position: fixed; inset: 0;
      background: rgba(0,0,0,0.6); z-index: 200;
      align-items: center; justify-content: center;
    }
    #progress-overlay.open { display: flex; }
    #progress-modal {
      background: #131f2e; border: 1px solid #1e5fa8; border-radius: 6px;
      width: 1120px; max-width: 95vw; max-height: 80vh;
      display: flex; flex-direction: column;
    }
    .pm-header {
      background: #1a2a3a; padding: 14px 18px;
      border-bottom: 1px solid #253545; border-radius: 6px 6px 0 0;
      display: flex; justify-content: space-between; align-items: center;
    }
    .pm-title { font-size: 0.95rem; font-weight: 600; color: #fff; }
    .pm-close {
      background: none; border: none; color: #7a9ab8;
      font-size: 1.4rem; cursor: pointer; line-height: 1; padding: 0;
    }
    .pm-close:hover { color: #fff; }
    .pm-log {
      font-family: 'Consolas', monospace; font-size: 0.72rem; color: #8ab0c8;
      background: #0a1018; padding: 14px 16px; flex: 1;
      overflow-y: auto; white-space: pre-wrap; word-break: break-all;
      min-height: 200px; max-height: 50vh;
    }
    .pm-footer {
      padding: 12px 18px; border-top: 1px solid #253545;
      display: flex; justify-content: flex-end;
    }
    .pm-done-btn {
      background: #1a2535; border: 1px solid #2a3a4a; border-radius: 4px;
      color: #7a9ab8; font-size: 0.85rem; padding: 8px 20px; cursor: pointer;
    }
    .pm-done-btn:hover { border-color: #2a6ab0; color: #fff; }

    /* ---- hosts editor panel ---- */
    #hosts-overlay {
      display: none; position: fixed; inset: 0;
      background: rgba(0,0,0,0.45); z-index: 100;
    }
    #hosts-overlay.open { display: block; }

    #hosts-panel {
      position: fixed;
      top: 0; right: 0;
      width: 420px;
      height: 100vh;
      background: #131f2e;
      border-left: 3px solid #1e5fa8;
      z-index: 101;
      display: flex;
      flex-direction: column;
      transform: translateX(100%);
      transition: transform 0.25s ease;
    }
    #hosts-panel.open { transform: translateX(0); }

    .hp-header {
      background: #1a2a3a; padding: 16px 18px;
      border-bottom: 1px solid #253545; flex-shrink: 0;
      display: flex; align-items: center; justify-content: space-between;
    }
    .hp-title { font-size: 1rem; font-weight: 600; color: #fff; }
    .hp-subtitle { font-size: 0.7rem; color: #5a7a9a; margin-top: 3px; }
    .hp-close {
      background: none; border: none; color: #7a9ab8; font-size: 1.4rem;
      cursor: pointer; line-height: 1; padding: 0;
    }
    .hp-close:hover { color: #fff; }

    .hp-body { padding: 16px 18px; flex: 1; display: flex; flex-direction: column; overflow: hidden; }
    .hp-hint {
      font-size: 0.68rem; color: #5a7a9a; margin-bottom: 10px; line-height: 1.5;
    }
    .hp-hint code { background: #0f1923; padding: 1px 4px; border-radius: 2px; font-family: 'Consolas', monospace; color: #8ab0c8; }

    #hosts-textarea {
      flex: 1;
      width: 100%;
      background: #0a1018;
      border: 1px solid #253545;
      border-radius: 4px;
      color: #c8d8e8;
      font-family: 'Consolas', 'Courier New', monospace;
      font-size: 0.75rem;
      line-height: 1.6;
      padding: 10px 12px;
      resize: none;
      outline: none;
      transition: border-color 0.15s;
      min-height: 0;
    }
    #hosts-textarea:focus { border-color: #2a6ab0; }

    .hp-message {
      margin-top: 10px; padding: 8px 12px; border-radius: 4px;
      font-size: 0.78rem; display: none;
    }
    .hp-message.error   { background: #4a1a1a; border: 1px solid #c0392b; color: #e07070; display: block; }
    .hp-message.success { background: #1a4a2a; border: 1px solid #27ae60; color: #5dca80; display: block; }

    .hp-footer {
      padding: 14px 18px 20px; display: flex; gap: 10px; flex-shrink: 0;
    }
    .hp-save {
      flex: 1; background: #1e5fa8; border: none; border-radius: 4px;
      color: #fff; font-size: 0.85rem; font-weight: 600; padding: 10px;
      cursor: pointer; transition: background 0.15s;
    }
    .hp-save:hover    { background: #2a7ad8; }
    .hp-save:disabled { background: #253545; color: #5a7a9a; cursor: not-allowed; }
    .hp-cancel {
      background: #1a2535; border: 1px solid #2a3a4a; border-radius: 4px;
      color: #7a9ab8; font-size: 0.85rem; padding: 10px 18px;
      cursor: pointer; transition: all 0.15s;
    }
    .hp-cancel:hover { border-color: #2a6ab0; color: #fff; }

    #camera-section { padding: 0 28px; overflow-x: auto; }

    .cam-grid {
      display: grid;
      grid-template-columns: 48px repeat(12, 1fr);
      gap: 6px;
      min-width: 900px;
    }

    /* column header row */
    .cam-col-header {
      font-size: 0.68rem;
      font-weight: 700;
      color: #3a6080;
      text-align: center;
      padding-bottom: 2px;
      letter-spacing: 0.05em;
    }
    .cam-col-header-spacer { /* empty top-left corner */ }

    /* each data row */
    .cam-row { display: contents; }

    .cam-row-label {
      font-size: 0.68rem;
      font-weight: 700;
      text-transform: uppercase;
      color: #5b9bd5;
      display: flex;
      align-items: flex-start;
      justify-content: flex-end;
      padding-right: 6px;
      padding-top: 6px;
      letter-spacing: 0.05em;
    }

    /* individual camera cell */
    .cam-cell {
      background: var(--bg-card);
      border: 1px solid var(--border);
      border-radius: 5px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }
    .cam-cell.up   { border-top: 3px solid #27ae60; }
    .cam-cell.down { border-top: 3px solid #c0392b; }

    .cam-info {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 4px 6px;
      gap: 4px;
    }
    .cam-ip {
      font-size: 0.6rem;
      color: #6a8aaa;
      font-family: 'Consolas', monospace;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      flex: 1;
    }
    .cam-status {
      font-size: 0.6rem;
      font-weight: 700;
      text-transform: uppercase;
      flex-shrink: 0;
    }
    .cam-status.up   { color: #27ae60; }
    .cam-status.down { color: #c0392b; }
    .cam-last-seen { font-size: 0.58rem; color: #c0392b; font-style: italic; padding: 0 6px 4px; }

    /* thumbnail */
    .cam-thumb-wrap {
      width: 100%;
      padding-top: 177.78%;  /* 16/9 inverted = 9/16 = 56.25%, but we want portrait so 16:9 rotated = height is 177.78% of width */
      position: relative;
      overflow: hidden;
    }
    .cam-thumb {
      position: absolute;
      /* image is 16:9 landscape; rotate 90deg CW to make it portrait */
      width: 177.78%;   /* image height becomes cell width: 100% / (9/16) */
      height: 56.25%;   /* image width scaled down to fit: 100% * (9/16) */
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%) rotate(90deg);
      object-fit: cover;
      display: block;
    }
    .cam-no-image {
      background: #111820;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 0.6rem;
      color: #3a5a7a;
      letter-spacing: 0.05em;
      text-transform: uppercase;
    }
  </style>
</head>
<body>
  <header>
    <div>
      <h1>KCC Pi Kiosk <span>Status Dashboard</span></h1>
      <div class="subtitle">Kelowna Curling Club</div>
    </div>
    <div style="text-align:right; display:flex; align-items:center; gap:12px;">
      <div>
        <div class="updated">Updated: $timestamp</div>
        <div class="refreshing" id="refresh-status">Refreshing in 15s</div>
      </div>
      <button class="theme-btn" id="theme-btn" onclick="toggleTheme()">&#9788; Light</button>
    </div>
  </header>

  <div id="global-toolbar">
    <button class="toolbar-btn danger" onclick="globalAction('reboot-all','Reboot All Pis','Are you sure you want to reboot all $($pis.Count) Pis?')">&#8635; Reboot All</button>
    <button class="toolbar-btn"        onclick="globalAction('software-update-all','Software Update — All Pis','Download latest files from GitHub to all $($pis.Count) Pis and reboot?')">&#11015; Software Update All</button>
    <button class="toolbar-btn"        onclick="globalAction('system-update-all','System Update — All Pis','Run apt update &amp; upgrade on all $($pis.Count) Pis? This will take several minutes.')">&#9881; System Update All</button>
    <button class="toolbar-btn" id="viewer-btn" onclick="toggleCameraViewer()">&#9654; Camera Viewer</button>
    <button class="toolbar-btn" onclick="openHostsPanel()">&#9998; Edit Pi Hosts</button>
    <button class="toolbar-btn danger" onclick="exitMonitor()" style="margin-left:auto">&#9211; Exit Monitor</button>
  </div>

  <div id="summary-bar">
    <div class="summary-item">
      <div class="summary-count $piSumClass">$pisOk/$pisTotal</div>
      <div class="summary-label">Pis<br>online</div>
    </div>
    <div class="summary-item">
      <div class="summary-count $svcSumClass">$svcActive/$pisTotal</div>
      <div class="summary-label">Kiosk service<br>active</div>
    </div>
    <div class="summary-item">
      <div class="summary-count $camSumClass">$camsUp/$camsTotal</div>
      <div class="summary-label">Cameras<br>reachable</div>
    </div>
  </div>

  <div class="section-title">Raspberry Pi Fleet</div>
  <div id="pi-grid">
$piCards
  </div>

  <div class="section-title">Camera Feeds</div>
  <div id="camera-section">
    <div class="cam-grid">
      <!-- column headers -->
      <div class="cam-col-header-spacer"></div>
$colHeaders
      <!-- Away row -->
$awayRow
      <!-- Home row -->
$homeRow
    </div>
  </div>

  <!-- progress modal -->
  <div id="progress-overlay">
    <div id="progress-modal">
      <div class="pm-header">
        <div class="pm-title" id="pm-title">Progress</div>
        <button class="pm-close" id="pm-close-btn" onclick="closeProgressModal()" style="display:none">×</button>
      </div>
      <div class="pm-log" id="pm-log"></div>
      <div class="pm-footer">
        <button class="pm-done-btn" id="pm-done-btn" onclick="closeProgressModal()" style="display:none">Close</button>
      </div>
    </div>
  </div>

  <!-- config panel overlay -->
  <div id="config-overlay" onclick="closeConfigPanel()"></div>

  <!-- config panel -->
  <div id="config-panel">
    <div class="cp-header">
      <div style="flex:1; min-width:0;">
        <div style="display:flex; align-items:center; gap:6px;">
          <div class="cp-title" id="cp-pi-name">kcc-pi-01</div>
          <button class="cp-rename-icon" id="cp-rename-icon" onclick="startRename()" title="Rename Pi">&#9998;</button>
          <input class="cp-rename-input" id="cp-rename-input" type="text" style="display:none"
                 onkeydown="if(event.key==='Enter')confirmRename(); if(event.key==='Escape')cancelRename();">
          <button class="cp-rename-confirm" id="cp-rename-confirm" onclick="confirmRename()" style="display:none" title="Confirm rename">&#10003;</button>
          <button class="cp-rename-cancel"  id="cp-rename-cancel"  onclick="cancelRename()"  style="display:none" title="Cancel">&#10007;</button>
        </div>
        <div class="cp-ip" id="cp-pi-ip">10.200.30.11</div>
      </div>
      <button class="cp-close" onclick="closeConfigPanel()">×</button>
    </div>

    <div class="cp-body">
      <!-- rotation -->
      <div class="cp-section">
        <div class="cp-label">Rotation</div>
        <div class="toggle-group" id="cp-rotation">
          <button class="toggle-btn" data-val="H" onclick="setToggle('cp-rotation',this)">H — Horizontal</button>
          <button class="toggle-btn" data-val="V" onclick="setToggle('cp-rotation',this)">V — Vertical</button>
        </div>
      </div>

      <!-- mode -->
      <div class="cp-section">
        <div class="cp-label">Mode</div>
        <div class="toggle-group" id="cp-mode">
          <button class="toggle-btn" data-val="C" onclick="setToggle('cp-mode',this);updateModeFields()">Cameras</button>
          <button class="toggle-btn" data-val="S" onclick="setToggle('cp-mode',this);updateModeFields()">Single</button>
          <button class="toggle-btn" data-val="K" onclick="setToggle('cp-mode',this);updateModeFields()">Kiosk</button>
        </div>
      </div>

      <!-- cameras: sheet pair -->
      <div class="cp-section" id="cp-field-cameras">
        <div class="cp-label">Sheet Pair</div>
        <select class="cp-select" id="cp-pair" onchange="updatePreview()">
          <option value="0102">Sheets 1 &amp; 2</option>
          <option value="0304">Sheets 3 &amp; 4</option>
          <option value="0506">Sheets 5 &amp; 6</option>
          <option value="0708">Sheets 7 &amp; 8</option>
          <option value="0910">Sheets 9 &amp; 10</option>
          <option value="1112">Sheets 11 &amp; 12</option>
        </select>
      </div>

      <!-- single: sheet number -->
      <div class="cp-section" id="cp-field-single" style="display:none">
        <div class="cp-label">Sheet</div>
        <select class="cp-select" id="cp-sheet" onchange="updatePreview()">
          <option value="01">Sheet 1</option>
          <option value="02">Sheet 2</option>
          <option value="03">Sheet 3</option>
          <option value="04">Sheet 4</option>
          <option value="05">Sheet 5</option>
          <option value="06">Sheet 6</option>
          <option value="07">Sheet 7</option>
          <option value="08">Sheet 8</option>
          <option value="09">Sheet 9</option>
          <option value="10">Sheet 10</option>
          <option value="11">Sheet 11</option>
          <option value="12">Sheet 12</option>
        </select>
      </div>

      <!-- kiosk: channel -->
      <div class="cp-section" id="cp-field-kiosk" style="display:none">
        <div class="cp-label">Channel</div>
        <div class="toggle-group" id="cp-kiosk">
          <button class="toggle-btn" data-val="01" onclick="setToggle('cp-kiosk',this)">Upstairs</button>
          <button class="toggle-btn" data-val="02" onclick="setToggle('cp-kiosk',this)">Practice Ice</button>
        </div>
      </div>

      <!-- resolution -->
      <div class="cp-section">
        <div class="cp-label">Resolution</div>
        <div class="cp-res-row">
          <select class="cp-select" id="cp-resolution">
            <option value="">Loading…</option>
          </select>
          <button class="cp-res-apply" id="cp-res-apply-btn" onclick="applyResolution()">Apply</button>
        </div>
      </div>

      <!-- preview -->      
      <div class="cp-preview">
        <span class="cp-preview-code"  id="cp-code">HC0102</span>
        <div  class="cp-preview-label" id="cp-label-text">Horizontal · Cameras · Sheets 1 &amp; 2</div>
      </div>
    </div>

    <div class="cp-message" id="cp-message"></div>

    <div class="cp-actions">
      <button class="cp-action-btn" id="cp-sw-update-btn"      onclick="doSoftwareUpdate()">&#11015; Software Update</button>
      <button class="cp-action-btn" id="cp-sys-update-btn"     onclick="doSystemUpdate()">&#9881; System Update</button>
      <button class="cp-action-btn" id="cp-install-kiosk-btn"  onclick="doInstallKiosk()">&#9881; Install Kiosk</button>
    </div>

    <div class="cp-log" id="cp-log"></div>

    <div class="cp-footer">
      <button class="cp-apply"  id="cp-apply-btn" onclick="applyConfig()">Reboot</button>
      <button class="cp-cancel" onclick="closeConfigPanel()">Cancel</button>
    </div>
  </div>

  <!-- hosts editor overlay -->
  <div id="hosts-overlay" onclick="closeHostsPanel()"></div>

  <!-- hosts editor panel -->
  <div id="hosts-panel">
    <div class="hp-header">
      <div>
        <div class="hp-title">Edit Pi Hosts</div>
        <div class="hp-subtitle">pi-hosts.txt</div>
      </div>
      <button class="hp-close" onclick="closeHostsPanel()">×</button>
    </div>
    <div class="hp-body">
      <div class="hp-hint">
        One Pi per line: <code>&lt;ip-address&gt; &lt;hostname&gt;</code><br>
        Lines starting with <code>#</code> are comments and are ignored.
      </div>
      <textarea id="hosts-textarea" spellcheck="false"></textarea>
      <div class="hp-message" id="hp-message"></div>
    </div>
    <div class="hp-footer">
      <button class="hp-save" id="hp-save-btn" onclick="saveHosts()">Save</button>
      <button class="hp-cancel" onclick="closeHostsPanel()">Cancel</button>
    </div>
  </div>

  <script>
    const API = 'http://localhost:8080';
    let cpIp = '';
    let cpOriginalConfig = '';

    // ---- hosts editor ----
    const HOSTS_INITIAL = $hostsContentJson;

    function openHostsPanel() {
      const ta = document.getElementById('hosts-textarea');
      ta.value = HOSTS_INITIAL;
      document.getElementById('hp-message').className = 'hp-message';
      document.getElementById('hp-save-btn').disabled = false;
      document.getElementById('hp-save-btn').textContent = 'Save';
      document.getElementById('hosts-overlay').classList.add('open');
      document.getElementById('hosts-panel').classList.add('open');
      setPaused(true);
      ta.focus();
    }

    function closeHostsPanel() {
      document.getElementById('hosts-overlay').classList.remove('open');
      document.getElementById('hosts-panel').classList.remove('open');
      setPaused(false);
    }

    async function saveHosts() {
      const content = document.getElementById('hosts-textarea').value;
      const btn     = document.getElementById('hp-save-btn');
      const msgEl   = document.getElementById('hp-message');
      msgEl.className = 'hp-message';
      btn.disabled    = true;
      btn.textContent = 'Saving…';
      try {
        const resp = await fetch(API + '/save-hosts', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ content: content })
        });
        const data = await resp.json();
        if (data.success) {
          msgEl.textContent = 'Saved. The updated host list will take effect on the next poll cycle.';
          msgEl.className   = 'hp-message success';
          btn.textContent   = 'Saved';
          // reload after a short delay so the new file is picked up immediately
          setTimeout(() => { closeHostsPanel(); location.reload(); }, 1500);
        } else {
          msgEl.textContent = 'Error: ' + (data.error || 'Unknown error');
          msgEl.className   = 'hp-message error';
          btn.disabled      = false;
          btn.textContent   = 'Save';
        }
      } catch (e) {
        msgEl.textContent = 'Could not reach monitor service (localhost:8080). Is kiosk-monitor.ps1 running?';
        msgEl.className   = 'hp-message error';
        btn.disabled      = false;
        btn.textContent   = 'Save';
      }
    }

    // ---- rename Pi ----
    let cpOriginalName = '';

    function startRename() {
      cpOriginalName = document.getElementById('cp-pi-name').textContent;
      document.getElementById('cp-pi-name').style.display       = 'none';
      document.getElementById('cp-rename-icon').style.display    = 'none';
      document.getElementById('cp-rename-input').style.display   = 'inline-block';
      document.getElementById('cp-rename-confirm').style.display = 'inline-block';
      document.getElementById('cp-rename-cancel').style.display  = 'inline-block';
      const input = document.getElementById('cp-rename-input');
      input.value = cpOriginalName;
      input.focus();
      input.select();
    }

    function cancelRename() {
      document.getElementById('cp-pi-name').style.display       = '';
      document.getElementById('cp-rename-icon').style.display    = '';
      document.getElementById('cp-rename-input').style.display   = 'none';
      document.getElementById('cp-rename-confirm').style.display = 'none';
      document.getElementById('cp-rename-cancel').style.display  = 'none';
    }

    async function confirmRename() {
      const newName = document.getElementById('cp-rename-input').value.trim();
      if (!newName || newName === cpOriginalName) { cancelRename(); return; }

      const msgEl = document.getElementById('cp-message');
      msgEl.className = 'cp-message';
      setActionBtnsDisabled(true);

      try {
        const resp = await fetch(API + '/rename-pi', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ip: cpIp, hostname: newName })
        });
        const data = await resp.json();
        if (data.success) {
          document.getElementById('cp-pi-name').textContent = newName;
          cancelRename();
          showMessage('Renamed to ' + newName + ' — Pi is rebooting.', 'success');
        } else {
          showMessage('Error: ' + (data.error || 'Unknown error'), 'error');
        }
      } catch (e) {
        showMessage('Could not reach monitor service (localhost:8080).', 'error');
      }
      setActionBtnsDisabled(false);
    }

    function openConfigPanel(name, ip, currentConfig, currentRes) {
      cpIp             = ip;
      cpOriginalConfig = currentConfig;
      document.getElementById('cp-pi-name').textContent    = name;
      document.getElementById('cp-pi-ip').textContent      = ip;
      document.getElementById('cp-message').className      = 'cp-message';
      document.getElementById('cp-log').className          = 'cp-log';
      document.getElementById('cp-log').textContent        = '';
      document.getElementById('cp-apply-btn').disabled     = false;
      document.getElementById('cp-apply-btn').textContent  = 'Reboot';
      document.getElementById('cp-install-kiosk-btn').textContent = '⚙ Install Kiosk';
      setActionBtnsDisabled(false);

      // parse current config into controls
      const rot  = currentConfig[0] || 'H';
      const mode = currentConfig[1] || 'C';

      setToggleByVal('cp-rotation', rot);
      setToggleByVal('cp-mode', mode);
      updateModeFields();

      if (mode === 'C' && currentConfig.length >= 6) {
        const pair = currentConfig.substring(2, 6);
        const sel  = document.getElementById('cp-pair');
        for (let o of sel.options) { if (o.value === pair) { sel.value = pair; break; } }
      } else if (mode === 'S' && currentConfig.length >= 4) {
        document.getElementById('cp-sheet').value = currentConfig.substring(2, 4);
      } else if (mode === 'K' && currentConfig.length >= 4) {
        setToggleByVal('cp-kiosk', currentConfig.substring(2, 4));
      }

      updatePreview();
      fetchResolutions(currentRes);
      document.getElementById('config-overlay').classList.add('open');
      document.getElementById('config-panel').classList.add('open');
      setPaused(true);
    }

    function closeConfigPanel() {
      document.getElementById('config-overlay').classList.remove('open');
      document.getElementById('config-panel').classList.remove('open');
      cancelRename();
      setPaused(false);
    }

    function setToggle(groupId, btn) {
      document.querySelectorAll('#' + groupId + ' .toggle-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      updatePreview();
    }

    function setToggleByVal(groupId, val) {
      document.querySelectorAll('#' + groupId + ' .toggle-btn').forEach(b => {
        b.classList.toggle('active', b.dataset.val === val);
      });
    }

    function getToggleVal(groupId) {
      const btn = document.querySelector('#' + groupId + ' .toggle-btn.active');
      return btn ? btn.dataset.val : '';
    }

    function updateModeFields() {
      const mode = getToggleVal('cp-mode');
      document.getElementById('cp-field-cameras').style.display = mode === 'C' ? '' : 'none';
      document.getElementById('cp-field-single').style.display  = mode === 'S' ? '' : 'none';
      document.getElementById('cp-field-kiosk').style.display   = mode === 'K' ? '' : 'none';
      updatePreview();
    }

    function buildConfig() {
      const rot  = getToggleVal('cp-rotation') || 'H';
      const mode = getToggleVal('cp-mode')     || 'C';
      if (mode === 'C') {
        return rot + 'C' + document.getElementById('cp-pair').value;
      } else if (mode === 'S') {
        const s = document.getElementById('cp-sheet').value;
        return rot + 'S' + s + s;
      } else {
        const ch = getToggleVal('cp-kiosk') || '01';
        return rot + 'K' + ch + ch;
      }
    }

    function decodeConfig(cfg) {
      if (!cfg || cfg.length < 2) return '';
      const rot  = cfg[0] === 'H' ? 'Horizontal' : 'Vertical';
      const mode = cfg[1];
      if (mode === 'C' && cfg.length >= 6) {
        return rot + ' · Cameras · Sheets ' + parseInt(cfg.substring(2,4)) + ' & ' + parseInt(cfg.substring(4,6));
      } else if (mode === 'S' && cfg.length >= 4) {
        return rot + ' · Single · Sheet ' + parseInt(cfg.substring(2,4));
      } else if (mode === 'K' && cfg.length >= 4) {
        const loc = cfg.substring(2,4) === '01' ? 'Upstairs' : 'Practice Ice';
        return rot + ' · Kiosk · ' + loc;
      }
      return cfg;
    }

    function updatePreview() {
      const cfg     = buildConfig();
      const changed = cfg !== cpOriginalConfig;
      document.getElementById('cp-code').textContent       = cfg;
      document.getElementById('cp-label-text').textContent = decodeConfig(cfg);
      document.getElementById('cp-apply-btn').textContent  = changed ? 'Apply & Reboot' : 'Reboot';
    }

    function setActionBtnsDisabled(disabled) {
      document.getElementById('cp-sw-update-btn').disabled     = disabled;
      document.getElementById('cp-sys-update-btn').disabled    = disabled;
      document.getElementById('cp-install-kiosk-btn').disabled = disabled;
      document.getElementById('cp-apply-btn').disabled         = disabled;
    }

    function showMessage(msg, type) {
      const el = document.getElementById('cp-message');
      el.textContent = msg;
      el.className   = 'cp-message ' + type;
    }

    async function applyConfig() {
      const cfg = buildConfig();
      const btn = document.getElementById('cp-apply-btn');
      document.getElementById('cp-message').className = 'cp-message';
      setActionBtnsDisabled(true);
      btn.textContent = 'Applying…';
      try {
        const resp = await fetch(API + '/set-config', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ip: cpIp, config: cfg })
        });
        const data = await resp.json();
        if (data.success) {
          closeConfigPanel();
        } else {
          showMessage('Error: ' + (data.error || 'Unknown error'), 'error');
          setActionBtnsDisabled(false);
          updatePreview();
        }
      } catch (e) {
        showMessage('Could not reach monitor service (localhost:8080). Is kiosk-monitor.ps1 running?', 'error');
        setActionBtnsDisabled(false);
        updatePreview();
      }
    }

    async function doInstallKiosk() {
      document.getElementById('cp-message').className = 'cp-message';
      const logEl = document.getElementById('cp-log');
      logEl.textContent = '';
      logEl.className   = 'cp-log visible';
      setActionBtnsDisabled(true);
      document.getElementById('cp-install-kiosk-btn').textContent = 'Installing…';
      try {
        const resp = await fetch(API + '/install-kiosk', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ip: cpIp })
        });
        const reader  = resp.body.getReader();
        const decoder = new TextDecoder();
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          logEl.textContent += decoder.decode(value);
          logEl.scrollTop    = logEl.scrollHeight;
        }
        showMessage('Install complete.', 'success');
      } catch (e) {
        showMessage('Could not reach monitor service (localhost:8080).', 'error');
      }
      document.getElementById('cp-install-kiosk-btn').textContent = '⚙ Install Kiosk';
      setActionBtnsDisabled(false);
    }

    async function doSoftwareUpdate() {
      document.getElementById('cp-message').className = 'cp-message';
      document.getElementById('cp-log').className     = 'cp-log';
      setActionBtnsDisabled(true);
      document.getElementById('cp-sw-update-btn').textContent = 'Updating…';
      try {
        const resp = await fetch(API + '/software-update', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ip: cpIp })
        });
        const data = await resp.json();
        if (data.success) {
          showMessage('Software updated — Pi is rebooting.', 'success');
        } else {
          showMessage('Error: ' + (data.error || 'Unknown error'), 'error');
        }
      } catch (e) {
        showMessage('Could not reach monitor service (localhost:8080).', 'error');
      }
      document.getElementById('cp-sw-update-btn').textContent = '⬇ Software Update';
      setActionBtnsDisabled(false);
    }

    const KNOWN_RES = [
      { v: '3840x2160', l: '3840 × 2160  (4K)'   },
      { v: '2560x1440', l: '2560 × 1440  (1440p)' },
      { v: '1920x1080', l: '1920 × 1080  (1080p)' },
      { v: '1680x1050', l: '1680 × 1050'               },
      { v: '1600x900',  l: '1600 × 900'                },
      { v: '1366x768',  l: '1366 × 768'                },
      { v: '1280x1024', l: '1280 × 1024'               },
      { v: '1280x720',  l: '1280 × 720  (720p)'   },
    ];

    async function fetchResolutions(currentRes) {
      const sel = document.getElementById('cp-resolution');
      const btn = document.getElementById('cp-res-apply-btn');
      sel.innerHTML = '<option value="">Loading…</option>';
      sel.disabled  = true;
      btn.disabled  = true;
      try {
        const resp = await fetch(API + '/get-resolutions', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ip: cpIp })
        });
        const data = await resp.json();
        if (data.success && data.modes && data.modes.length > 0) {
          sel.innerHTML = '';
          data.modes.forEach(function(v) {
            const known = KNOWN_RES.find(function(k) { return k.v === v; });
            const label = known ? known.l : v;
            const opt   = document.createElement('option');
            opt.value       = v;
            opt.textContent = label;
            if (v === currentRes) { opt.selected = true; }
            sel.appendChild(opt);
          });
        } else {
          sel.innerHTML = '<option value="">Could not load modes</option>';
        }
      } catch (e) {
        sel.innerHTML = '<option value="">Error loading modes</option>';
      }
      sel.disabled = false;
      btn.disabled = false;
    }

    async function applyResolution() {
      const mode  = document.getElementById('cp-resolution').value;
      const btn   = document.getElementById('cp-res-apply-btn');
      const msgEl = document.getElementById('cp-message');
      msgEl.className = 'cp-message';
      btn.disabled    = true;
      btn.textContent = 'Applying…';
      try {
        const resp = await fetch(API + '/set-resolution', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ip: cpIp, mode: mode })
        });
        const data = await resp.json();
        if (data.success) {
          showMessage('Resolution set to ' + mode + ' — kiosk restarting.', 'success');        } else {
          showMessage('Error: ' + (data.error || 'Unknown error'), 'error');
        }
      } catch (e) {
        showMessage('Could not reach monitor service (localhost:8080).', 'error');
      }
      btn.disabled    = false;
      btn.textContent = 'Apply';
    }

    async function doSystemUpdate() {
      document.getElementById('cp-message').className = 'cp-message';
      const logEl = document.getElementById('cp-log');
      logEl.textContent = '';
      logEl.className   = 'cp-log visible';
      setActionBtnsDisabled(true);
      document.getElementById('cp-sys-update-btn').textContent = 'Updating…';
      try {
        const resp = await fetch(API + '/system-update', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ip: cpIp })
        });
        const reader  = resp.body.getReader();
        const decoder = new TextDecoder();
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          logEl.textContent += decoder.decode(value);
          logEl.scrollTop    = logEl.scrollHeight;
        }
        showMessage('System update complete.', 'success');
      } catch (e) {
        showMessage('Could not reach monitor service (localhost:8080).', 'error');
      }
      document.getElementById('cp-sys-update-btn').textContent = '⚙ System Update';
      setActionBtnsDisabled(false);
    }
    function closeProgressModal() {
      document.getElementById('progress-overlay').classList.remove('open');
    }

    // ---- camera viewer ----
    let viewerRunning = false;

    async function checkViewerStatus() {
      try {
        const resp = await fetch(API + '/viewer-status', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({})
        });
        const data = await resp.json();
        viewerRunning = data.running;
        updateViewerBtn();
      } catch (e) { }
    }

    function updateViewerBtn() {
      const btn = document.getElementById('viewer-btn');
      if (viewerRunning) {
        btn.textContent = '✕ Close Viewer';
        btn.classList.add('danger');
      } else {
        btn.innerHTML = '&#9654; Camera Viewer';
        btn.classList.remove('danger');
      }
    }

    async function toggleCameraViewer() {
      const btn = document.getElementById('viewer-btn');
      btn.disabled = true;
      try {
        if (viewerRunning) {
          await fetch(API + '/close-camera-viewer', {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
          });
          viewerRunning = false;
        } else {
          const resp = await fetch(API + '/launch-camera-viewer', {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
          });
          const data = await resp.json();
          if (data.success) {
            viewerRunning = true;
          } else {
            alert('Camera Viewer error: ' + (data.error || 'Unknown error'));
          }
        }
      } catch (e) {
        alert('Could not reach monitor service (localhost:8080).');
      }
      updateViewerBtn();
      btn.disabled = false;
    }

    // check viewer status on load
    checkViewerStatus();

    // ---- dark / light mode ----
    function toggleTheme() {
      const isLight = document.body.classList.toggle('light');
      const btn     = document.getElementById('theme-btn');
      btn.innerHTML = isLight ? '&#9790; Dark' : '&#9788; Light';
      localStorage.setItem('kcc-theme', isLight ? 'light' : 'dark');
    }
    // restore saved theme
    if (localStorage.getItem('kcc-theme') === 'light') {
      document.body.classList.add('light');
      document.getElementById('theme-btn').innerHTML = '&#9790; Dark';
    }

    // ---- countdown timer + auto-pause ----
    const REFRESH_SECS = 15;
    let countdown = REFRESH_SECS;
    let paused    = false;

    function setPaused(val) {
      paused = val;
      updateRefreshStatus();
    }

    function updateRefreshStatus() {
      const el = document.getElementById('refresh-status');
      if (!el) return;
      if (paused) {
        el.textContent = 'Refresh paused';
        el.style.color = 'var(--warn)';
      } else {
        el.textContent = countdown > 0 ? 'Refreshing in ' + countdown + 's' : 'Refreshing...';
        el.style.color = '';
      }
    }

    setInterval(() => {
      if (paused) return;
      countdown--;
      updateRefreshStatus();
      if (countdown <= 0) {
        countdown = REFRESH_SECS;
        location.reload();
      }
    }, 1000);

    // ---- exit monitor ----
    async function exitMonitor() {
      if (!confirm('Stop the kiosk monitor script?')) return;
      setPaused(true);
      try {
        await fetch(API + '/exit', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: '{}'
        });
      } catch (e) { }
      document.body.innerHTML = '<div style="display:flex;align-items:center;justify-content:center;height:100vh;flex-direction:column;gap:16px;font-family:sans-serif;background:#0f1923;color:#e0e0e0;">' +
        '<div style="font-size:2rem;">&#9211;</div>' +
        '<div style="font-size:1.2rem;font-weight:600;">Monitor stopped.</div>' +
        '<div style="font-size:0.85rem;color:#7a9ab8;">You can close this tab.</div>' +
        '</div>';
    }

    async function globalAction(endpoint, title, confirmMsg) {
      if (!confirm(confirmMsg)) return;
      setPaused(true);

      const overlay  = document.getElementById('progress-overlay');
      const logEl    = document.getElementById('pm-log');
      const titleEl  = document.getElementById('pm-title');
      const closeBtn = document.getElementById('pm-close-btn');
      const doneBtn  = document.getElementById('pm-done-btn');

      titleEl.textContent  = title;
      logEl.textContent    = '';
      closeBtn.style.display = 'none';
      doneBtn.style.display  = 'none';
      overlay.classList.add('open');

      try {
        const resp = await fetch(API + '/' + endpoint, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({})
        });
        const reader  = resp.body.getReader();
        const decoder = new TextDecoder();
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          logEl.textContent += decoder.decode(value);
          logEl.scrollTop    = logEl.scrollHeight;
        }
      } catch (e) {
        logEl.textContent += '\nERROR: Could not reach monitor service (localhost:8080).';
      }

      closeBtn.style.display = 'inline-block';
      doneBtn.style.display  = 'inline-block';
    }

    function closeProgressModal() {
      document.getElementById('progress-overlay').classList.remove('open');
      setPaused(false);
    }

  </script>
</body>
</html>
"@

    $html | Set-Content $HTML_FILE -Encoding UTF8
}

# --------------------------------------------------------------------------------
# poll loop — parallel
# --------------------------------------------------------------------------------
function Invoke-Poll($pis, $camEnv, $lastSeenPis, $lastSeenCams) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $now       = Get-Date
    Write-Host "[$timestamp] Polling $($pis.Count) Pis and $($camEnv.CAM_HOME.Count + $camEnv.CAM_AWAY.Count) cameras (parallel)..."

    # ---- poll all Pis in parallel ----
    $piResults = $pis | ForEach-Object -Parallel {
        $pi         = $_
        $SSH_PORT   = $using:SSH_PORT

        function Test-TcpPortLocal($ip, $port) {
            try {
                $tcp  = New-Object System.Net.Sockets.TcpClient
                $conn = $tcp.BeginConnect($ip, $port, $null, $null)
                $wait = $conn.AsyncWaitHandle.WaitOne(2000, $false)
                if ($wait) { $tcp.EndConnect($conn); $tcp.Close(); return $true }
                $tcp.Close(); return $false
            } catch { return $false }
        }

        function Test-PingLocal($ip) {
            try {
                if ($using:IS_WINDOWS) {
                    return (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue)
                } else {
                    & ping -c 1 -W 2 $ip 2>&1 | Out-Null
                    return ($LASTEXITCODE -eq 0)
                }
            } catch { return $false }
        }

        function Invoke-SSHLocal($ip, $command) {
            if (-not $using:SSH) { return "unknown" }
            try {
                $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5",
                             "-p", $using:SSH_PORT, "$($using:SSH_USER)@${ip}")
                if ($using:IS_WINDOWS) {
                    $out = & $using:SSH @sshOpts $command 2>&1
                } else {
                    if (-not $using:SSHPASS) { return "unknown" }
                    $out = & $using:SSHPASS -p $using:SSH_PASS $using:SSH @sshOpts $command 2>&1
                }
                return ($out -join "").Trim()
            } catch { return "" }
        }

        $ping   = Test-PingLocal $pi.IP
        $ssh    = if ($ping) { Test-TcpPortLocal $pi.IP $SSH_PORT } else { $false }
        $svc    = if ($ssh)  { Invoke-SSHLocal $pi.IP "systemctl is-active kiosk.service" } else { "unknown" }
        $svc    = switch ($svc) { "active"{"active"} "inactive"{"inactive"} "failed"{"failed"} default{"unknown"} }
        $config = if ($ssh)  { (Invoke-SSHLocal $pi.IP "cat /home/kcckiosk/kiosk.config 2>/dev/null").Trim() } else { "" }
        $uptime = if ($ssh)  { (Invoke-SSHLocal $pi.IP "uptime -p 2>/dev/null").Trim() } else { "" }
        $res    = if ($ssh)  { (Invoke-SSHLocal $pi.IP "kmsprint 2>/dev/null | awk '/Crtc/ { match(`$0, /[0-9]+x[0-9]+/); print substr(`$0, RSTART, RLENGTH); exit }'").Trim() } else { "" }

        Write-Host "  Pi $($pi.Name) ($($pi.IP)) ping=$ping ssh=$ssh service=$svc config=$config uptime=$uptime res=$res"
        @{ name = $pi.Name; ip = $pi.IP; ping = $ping; ssh = $ssh; service = $svc; config = $config; uptime = $uptime; resolution = $res }

    } -ThrottleLimit 13

    # sort Pi results by name so cards always appear in order
    $piResults = $piResults | Sort-Object { $_.name }

    # update last seen for Pis
    foreach ($pi in $piResults) {
        if ($pi.ping) {
            $lastSeenPis[$pi.ip] = $now
        }
        $lastSeen = if ($lastSeenPis.ContainsKey($pi.ip)) {
            $mins = [int]($now - $lastSeenPis[$pi.ip]).TotalMinutes
            if ($mins -eq 0) { "less than 1 min ago" } elseif ($mins -eq 1) { "1 min ago" } else { "$mins mins ago" }
        } else { "never" }
        $pi.lastSeen = if ($pi.ping) { "" } else { $lastSeen }
    }

    # write dashboard with Pi results immediately (no camera snapshots yet)
    $emptyCamResults = @()
    for ($i = 0; $i -lt $camEnv.CAM_AWAY.Count; $i++) {
        $emptyCamResults += @{ sheet = $i+1; end = "Away"; ip = $camEnv.CAM_AWAY[$i]; up = $false; snapshot = "" }
    }
    for ($i = 0; $i -lt $camEnv.CAM_HOME.Count; $i++) {
        $emptyCamResults += @{ sheet = $i+1; end = "Home"; ip = $camEnv.CAM_HOME[$i]; up = $false; snapshot = "" }
    }
    Write-Dashboard $timestamp $piResults $emptyCamResults $camEnv.CAM_USER $camEnv.CAM_PASS
    Write-Host "  Dashboard written (Pis done, cameras pending)..."

    # ---- poll all cameras in parallel ----
    $allCamInputs = @()
    for ($i = 0; $i -lt $camEnv.CAM_AWAY.Count; $i++) {
        $allCamInputs += @{ sheet = $i+1; end = "Away"; ip = $camEnv.CAM_AWAY[$i] }
    }
    for ($i = 0; $i -lt $camEnv.CAM_HOME.Count; $i++) {
        $allCamInputs += @{ sheet = $i+1; end = "Home"; ip = $camEnv.CAM_HOME[$i] }
    }

    $camResults = $allCamInputs | ForEach-Object -Parallel {
        $cam      = $_
        $RTSP_PORT = $using:RTSP_PORT

        function Test-TcpPortLocal($ip, $port) {
            try {
                $tcp  = New-Object System.Net.Sockets.TcpClient
                $conn = $tcp.BeginConnect($ip, $port, $null, $null)
                $wait = $conn.AsyncWaitHandle.WaitOne(2000, $false)
                if ($wait) { $tcp.EndConnect($conn); $tcp.Close(); return $true }
                $tcp.Close(); return $false
            } catch { return $false }
        }

        $up       = Test-TcpPortLocal $cam.ip $RTSP_PORT
        $snapshot = ""
        if ($up) {
            try {
                $tmpFile = [System.IO.Path]::GetTempFileName()
                & curl --digest --user "$($using:camEnv.CAM_USER):$($using:camEnv.CAM_PASS)" `
                       "http://$($cam.ip)/axis-cgi/jpg/image.cgi" `
                       -o $tmpFile --silent --max-time 5 2>$null
                if (Test-Path $tmpFile) {
                    $bytes = [System.IO.File]::ReadAllBytes($tmpFile)
                    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
                    if ($bytes.Length -gt 0) { $snapshot = [Convert]::ToBase64String($bytes) }
                }
            } catch { }
        }

        Write-Host "  Camera $($cam.end) sheet $($cam.sheet) ($($cam.ip)) up=$up snapshot=$(if ($snapshot -ne '') { 'ok' } else { 'failed' })"
        @{ sheet = $cam.sheet; end = $cam.end; ip = $cam.ip; up = $up; snapshot = $snapshot }

    } -ThrottleLimit 26

    # update last seen for cameras
    foreach ($cam in $camResults) {
        if ($cam.up) {
            $lastSeenCams[$cam.ip] = $now
        }
        $lastSeen = if ($lastSeenCams.ContainsKey($cam.ip)) {
            $mins = [int]($now - $lastSeenCams[$cam.ip]).TotalMinutes
            if ($mins -eq 0) { "less than 1 min ago" } elseif ($mins -eq 1) { "1 min ago" } else { "$mins mins ago" }
        } else { "never" }
        $cam.lastSeen = if ($cam.up) { "" } else { $lastSeen }
    }

    # write final dashboard with camera results
    Write-Dashboard $timestamp $piResults $camResults $camEnv.CAM_USER $camEnv.CAM_PASS
    Write-Host "  Dashboard written (complete)"
    Write-Host ""
}

# --------------------------------------------------------------------------------
# HTTP listener — runs in a background runspace on localhost:8080
# Handles all browser-to-script actions
# --------------------------------------------------------------------------------
function Start-HttpListener {
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable("HTTP_PORT",  $script:HTTP_PORT)
    $rs.SessionStateProxy.SetVariable("SSH_USER",   $script:SSH_USER)
    $rs.SessionStateProxy.SetVariable("SSH_PASS",   $script:SSH_PASS)
    $rs.SessionStateProxy.SetVariable("SSH_PORT",   $script:SSH_PORT)
    $rs.SessionStateProxy.SetVariable("IS_WINDOWS", $script:IS_WINDOWS)
    $rs.SessionStateProxy.SetVariable("SSH",        $script:SSH)
    $rs.SessionStateProxy.SetVariable("SSHPASS",    $script:SSHPASS)
    $rs.SessionStateProxy.SetVariable("HOSTS_FILE", $script:HOSTS_FILE)
    $rs.SessionStateProxy.SetVariable("FFPLAY",     $script:FFPLAY)
    $rs.SessionStateProxy.SetVariable("CAM_ENV",    $script:camEnv)
    $rs.SessionStateProxy.SetVariable("SCRIPT_DIR", $script:SCRIPT_DIR)
    $rs.SessionStateProxy.SetVariable("HTML_FILE",  $script:HTML_FILE)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript({
        function Invoke-SSH-Local($ip, $command) {
            try {
                $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                             "-p", $SSH_PORT, "${SSH_USER}@${ip}")
                if ($IS_WINDOWS) {
                    $out = & $SSH @sshOpts $command 2>&1
                } else {
                    $out = & $SSHPASS -p $SSH_PASS $SSH @sshOpts $command 2>&1
                }
                return ($out -join "").Trim()
            } catch { return "" }
        }

        function Load-Hosts-Local {
            $hosts = @()
            if (-not (Test-Path $HOSTS_FILE)) { return $hosts }
            foreach ($line in Get-Content $HOSTS_FILE) {
                $line = $line.Trim()
                if ($line -eq "" -or $line.StartsWith("#")) { continue }
                $parts = $line -split '\s+'
                if ($parts.Count -ge 2) {
                    $hosts += [PSCustomObject]@{ IP = $parts[0]; Name = $parts[1] }
                }
            }
            return $hosts
        }

        # run a command on all Pis sequentially, stream results to writer
        function Invoke-AllSequential($pis, $command, $writer) {
            foreach ($pi in $pis) {
                $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                             "-p", $SSH_PORT, "${SSH_USER}@$($pi.IP)")
                try {
                    if ($IS_WINDOWS) {
                        & $SSH @sshOpts $command 2>&1 | Out-Null
                    } else {
                        & $SSHPASS -p $SSH_PASS $SSH @sshOpts $command 2>&1 | Out-Null
                    }
                    $writer.WriteLine("$($pi.Name) ($($pi.IP)): OK")
                } catch {
                    $writer.WriteLine("$($pi.Name) ($($pi.IP)): FAILED — $_")
                }
            }
        }

        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:${HTTP_PORT}/")
        $listener.Start()

        while ($listener.IsListening) {
            try {
                $ctx      = $listener.GetContext()
                $req      = $ctx.Request
                $resp     = $ctx.Response
                $resp.ContentType = "application/json"
                $resp.Headers.Add("Access-Control-Allow-Origin", "*")
                $resp.Headers.Add("Access-Control-Allow-Methods", "POST, OPTIONS")
                $resp.Headers.Add("Access-Control-Allow-Headers", "Content-Type")

                if ($req.HttpMethod -eq "OPTIONS") {
                    $resp.StatusCode = 200
                    $resp.Close()
                    continue
                }

                Write-Host "  [HTTP] $($req.HttpMethod) $($req.Url.AbsolutePath)"

                # serve the dashboard HTML on GET /
                if ($req.HttpMethod -eq "GET" -and $req.Url.AbsolutePath -eq "/") {
                    $resp.ContentType = "text/html; charset=utf-8"
                    if (Test-Path $HTML_FILE) {
                        $htmlBytes = [System.IO.File]::ReadAllBytes($HTML_FILE)
                        $resp.ContentLength64 = $htmlBytes.Length
                        $resp.OutputStream.Write($htmlBytes, 0, $htmlBytes.Length)
                    } else {
                        $msg = [System.Text.Encoding]::UTF8.GetBytes("<html><body>Dashboard not ready yet. Please wait...</body></html>")
                        $resp.ContentLength64 = $msg.Length
                        $resp.OutputStream.Write($msg, 0, $msg.Length)
                    }
                    $resp.Close()
                    continue
                }

                $body   = New-Object System.IO.StreamReader($req.InputStream)
                $json   = $body.ReadToEnd() | ConvertFrom-Json
                $result = ""

                if ($req.Url.AbsolutePath -eq "/set-config") {
                    $ip     = $json.ip
                    $config = $json.config
                    if ($ip -and $config) {
                        Invoke-SSH-Local $ip "echo '$config' > /home/kcckiosk/kiosk.config && sudo sync && sudo reboot" | Out-Null
                        $result = '{"success":true}'
                    } else {
                        $resp.StatusCode = 400
                        $result = '{"success":false,"error":"Missing ip or config"}'
                    }

                } elseif ($req.Url.AbsolutePath -eq "/software-update") {
                    $ip = $json.ip
                    if ($ip) {
                        $cmd = 'wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.service     --no-verbose -O /home/kcckiosk/kiosk.service && ' +
                               'wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.run.sh      --no-verbose -O /home/kcckiosk/kiosk.run.sh && ' +
                               'wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.env         --no-verbose -O /home/kcckiosk/kiosk.env && ' +
                               'wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/wifi-watchdog.sh  --no-verbose -O /home/kcckiosk/wifi-watchdog.sh && ' +
                               'wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/unclutter.service --no-verbose -O /home/kcckiosk/unclutter.service && ' +
                               'echo "__DONE__" && sudo reboot'
                        Invoke-SSH-Local $ip $cmd | Out-Null
                        $result = '{"success":true}'
                    } else {
                        $resp.StatusCode = 400
                        $result = '{"success":false,"error":"Missing ip"}'
                    }

                } elseif ($req.Url.AbsolutePath -eq "/system-update") {
                    $ip = $json.ip
                    if ($ip) {
                        $resp.ContentType = "text/plain; charset=utf-8"
                        $resp.SendChunked = $true
                        $writer = New-Object System.IO.StreamWriter($resp.OutputStream, [System.Text.Encoding]::UTF8)
                        $writer.AutoFlush = $true
                        try {
                            $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                                         "-p", $SSH_PORT, "${SSH_USER}@${ip}")
                            $cmd = "sudo DEBIAN_FRONTEND=noninteractive stdbuf -oL apt-get update 2>&1 && sudo DEBIAN_FRONTEND=noninteractive stdbuf -oL apt-get upgrade -y 2>&1"
                            if ($IS_WINDOWS) {
                                & $SSH @sshOpts $cmd 2>&1 | ForEach-Object { $writer.WriteLine($_) }
                            } else {
                                & $SSHPASS -p $SSH_PASS $SSH @sshOpts $cmd 2>&1 | ForEach-Object { $writer.WriteLine($_) }
                            }
                        } catch {
                            $writer.WriteLine("ERROR: $_")
                        }
                        $writer.Close(); $resp.Close(); continue
                    } else {
                        $resp.StatusCode = 400
                        $result = '{"success":false,"error":"Missing ip"}'
                    }

                } elseif ($req.Url.AbsolutePath -eq "/reboot-all") {
                    $pis = Load-Hosts-Local
                    $resp.ContentType = "text/plain; charset=utf-8"
                    $resp.SendChunked = $true
                    $writer = New-Object System.IO.StreamWriter($resp.OutputStream, [System.Text.Encoding]::UTF8)
                    $writer.AutoFlush = $true
                    $writer.WriteLine("Rebooting $($pis.Count) Pi(s)...")
                    foreach ($pi in $pis) {
                        $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                                     "-p", $SSH_PORT, "${SSH_USER}@$($pi.IP)")
                        try {
                            if ($IS_WINDOWS) {
                                & $SSH @sshOpts "sudo /sbin/shutdown -r now" 2>&1 | Out-Null
                            } else {
                                & $SSHPASS -p $SSH_PASS $SSH @sshOpts "sudo /sbin/shutdown -r now" 2>&1 | Out-Null
                            }
                            $writer.WriteLine("$($pi.Name) ($($pi.IP)): OK")

                        } catch {
                            $writer.WriteLine("$($pi.Name) ($($pi.IP)): FAILED — $_")
                        }
                    }
                    $writer.WriteLine("Done.")
                    $writer.Close(); $resp.Close(); continue

                } elseif ($req.Url.AbsolutePath -eq "/software-update-all") {
                    $pis = Load-Hosts-Local
                    $resp.ContentType = "text/plain; charset=utf-8"
                    $resp.SendChunked = $true
                    $writer = New-Object System.IO.StreamWriter($resp.OutputStream, [System.Text.Encoding]::UTF8)
                    $writer.AutoFlush = $true
                    $swCmd = 'wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.service     --no-verbose -O /home/kcckiosk/kiosk.service && ' +
                             'wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.run.sh      --no-verbose -O /home/kcckiosk/kiosk.run.sh && ' +
                             'wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.env         --no-verbose -O /home/kcckiosk/kiosk.env && ' +
                             'wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/wifi-watchdog.sh  --no-verbose -O /home/kcckiosk/wifi-watchdog.sh && ' +
                             'wget https://raw.githubusercontent.com/garjones/pi-kiosk/main/unclutter.service --no-verbose -O /home/kcckiosk/unclutter.service && ' +
                             'sudo reboot'
                    $writer.WriteLine("Updating $($pis.Count) Pi(s)...")
                    foreach ($pi in $pis) {
                        $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                                     "-p", $SSH_PORT, "${SSH_USER}@$($pi.IP)")
                        try {
                            if ($IS_WINDOWS) {
                                & $SSH @sshOpts $swCmd 2>&1 | Out-Null
                            } else {
                                & $SSHPASS -p $SSH_PASS $SSH @sshOpts $swCmd 2>&1 | Out-Null
                            }
                            $writer.WriteLine("$($pi.Name) ($($pi.IP)): OK")
                        } catch {
                            $writer.WriteLine("$($pi.Name) ($($pi.IP)): FAILED — $_")
                        }
                    }
                    $writer.WriteLine("Done.")
                    $writer.Close(); $resp.Close(); continue

                } elseif ($req.Url.AbsolutePath -eq "/system-update-all") {
                    $pis = Load-Hosts-Local
                    $resp.ContentType = "text/plain; charset=utf-8"
                    $resp.SendChunked = $true
                    $writer = New-Object System.IO.StreamWriter($resp.OutputStream, [System.Text.Encoding]::UTF8)
                    $writer.AutoFlush = $true
                    $writer.WriteLine("Running system update on $($pis.Count) Pi(s) sequentially...")
                    $cmd = "sudo DEBIAN_FRONTEND=noninteractive stdbuf -oL apt-get update 2>&1 && sudo DEBIAN_FRONTEND=noninteractive stdbuf -oL apt-get upgrade -y 2>&1"
                    foreach ($pi in $pis) {
                        $writer.WriteLine("")
                        $writer.WriteLine("--- $($pi.Name) ($($pi.IP)) ---")
                        $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                                     "-p", $SSH_PORT, "${SSH_USER}@$($pi.IP)")
                        try {
                            if ($IS_WINDOWS) {
                                & $SSH @sshOpts $cmd 2>&1 | ForEach-Object { $writer.WriteLine($_) }
                            } else {
                                & $SSHPASS -p $SSH_PASS $SSH @sshOpts $cmd 2>&1 | ForEach-Object { $writer.WriteLine($_) }
                            }
                            $writer.WriteLine("--- $($pi.Name): Done ---")
                        } catch {
                            $writer.WriteLine("--- $($pi.Name): FAILED — $_ ---")
                        }
                    }
                    $writer.WriteLine("")
                    $writer.WriteLine("All done.")
                    $writer.Close(); $resp.Close(); continue

                } elseif ($req.Url.AbsolutePath -eq "/install-kiosk") {
                    $ip = $json.ip
                    if ($ip) {
                        $resp.ContentType = "text/plain; charset=utf-8"
                        $resp.SendChunked = $true
                        $writer = New-Object System.IO.StreamWriter($resp.OutputStream, [System.Text.Encoding]::UTF8)
                        $writer.AutoFlush = $true
                        try {
                            $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                                         "-p", $SSH_PORT, "${SSH_USER}@${ip}")
                            $cmd = @'
# create unclutter service symlink if needed
if [ ! -e /lib/systemd/system/unclutter.service ]; then
  sudo ln -s /home/kcckiosk/unclutter.service /lib/systemd/system/unclutter.service
  sudo systemctl enable unclutter.service
  echo "[Done] unclutter.service installed"
else
  echo "[Skip] unclutter.service already exists"
fi

# create kiosk service symlink if needed
if [ ! -e /lib/systemd/system/kiosk.service ]; then
  chmod u+x /home/kcckiosk/kiosk.run.sh
  sudo ln -s /home/kcckiosk/kiosk.service /lib/systemd/system/kiosk.service
  sudo systemctl enable kiosk.service
  echo "[Done] kiosk.service installed"
else
  echo "[Skip] kiosk.service already exists"
fi

# cron entries
(echo "0 7 * * * /sbin/shutdown -r now"; echo "*/15 * * * * /bin/bash /home/kcckiosk/wifi-watchdog.sh") | crontab -
echo "[Done] cron entries set"

# enable cron
sudo systemctl enable cron
sudo systemctl start cron
echo "[Done] cron enabled"

# disable desktop autostart
if [ -e /etc/xdg/labwc/autostart ]; then
  sudo mv /etc/xdg/labwc/autostart /etc/xdg/labwc/autostart.disabled
  echo "[Done] desktop autostart disabled"
else
  echo "[Skip] desktop autostart already disabled"
fi

# add kiosk autorun to .bashrc
if grep -Fxq "/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.sh)\"" /home/kcckiosk/.bashrc; then
  echo "[Skip] .bashrc autorun already set"
else
  echo "/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/garjones/pi-kiosk/main/kiosk.sh)\"" >> /home/kcckiosk/.bashrc
  echo "[Done] .bashrc autorun added"
fi

echo "Install complete."
'@
                            if ($IS_WINDOWS) {
                                & $SSH @sshOpts $cmd 2>&1 | ForEach-Object { $writer.WriteLine($_) }
                            } else {
                                & $SSHPASS -p $SSH_PASS $SSH @sshOpts $cmd 2>&1 | ForEach-Object { $writer.WriteLine($_) }
                            }
                        } catch {
                            $writer.WriteLine("ERROR: $_")
                        }
                        $writer.Close(); $resp.Close(); continue
                    } else {
                        $resp.StatusCode = 400
                        $result = '{"success":false,"error":"Missing ip"}'
                    }

                } elseif ($req.Url.AbsolutePath -eq "/get-resolutions") {
                    $ip = $json.ip
                    if ($ip) {
                        $cmd = 'WAYLAND_DISPLAY=wayland-0 wlr-randr | grep " px," | awk ''{print $1}'' | sort -u'
                        $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                                     "-p", $SSH_PORT, "${SSH_USER}@${ip}")
                        if ($IS_WINDOWS) {
                            $rawLines = & $SSH @sshOpts $cmd 2>&1
                        } else {
                            $rawLines = & $SSHPASS -p $SSH_PASS $SSH @sshOpts $cmd 2>&1
                        }
                        $raw = $rawLines -join " "
                        $knownRes = @('3840x2160','2560x1440','1920x1080','1680x1050','1600x900','1366x768','1280x1024','1280x720')
                        $available = @()
                        foreach ($res in $knownRes) {
                            if ($rawLines -contains $res) { $available += $res }
                        }
                        $modesJson = ($available | ForEach-Object { "`"$_`"" }) -join ","
                        $result = "{`"success`":true,`"modes`":[$modesJson]}"
                    } else {
                        $resp.StatusCode = 400
                        $result = '{"success":false,"error":"Missing ip"}'
                    }

                } elseif ($req.Url.AbsolutePath -eq "/set-resolution") {
                    $ip   = $json.ip
                    $mode = $json.mode
                    if ($ip -and $mode) {
                        $cmd = 'OUTPUT=$(WAYLAND_DISPLAY=wayland-0 wlr-randr | grep ''^HDMI'' | head -1 | awk ''{print $1}'') && ' +
                               "WAYLAND_DISPLAY=wayland-0 wlr-randr --output `"`$OUTPUT`" --mode $mode && " +
                               'sudo systemctl restart kiosk.service'
                        Invoke-SSH-Local $ip $cmd | Out-Null
                        $result = '{"success":true}'
                    } else {
                        $resp.StatusCode = 400
                        $result = '{"success":false,"error":"Missing ip or mode"}'
                    }

                } elseif ($req.Url.AbsolutePath -eq "/rename-pi") {
                    $ip      = $json.ip
                    $newName = $json.hostname
                    if ($ip -and $newName) {
                        Invoke-SSH-Local $ip "sudo hostnamectl set-hostname '$newName' && sudo sed -i 's/127.0.1.1.*/127.0.1.1\t$newName/' /etc/hosts && sudo reboot" | Out-Null
                        $result = '{"success":true}'
                    } else {
                        $resp.StatusCode = 400
                        $result = '{"success":false,"error":"Missing ip or hostname"}'
                    }

                } elseif ($req.Url.AbsolutePath -eq "/save-hosts") {
                    # write new pi-hosts.txt content to disk
                    # $json.content may be $null if the property is absent, or a string (even empty)
                    $content = if ($json -ne $null -and $json.PSObject.Properties['content']) { $json.content } else { $null }
                    if ($content -ne $null) {
                        try {
                            # normalise line endings and write atomically via temp file
                            $tmpPath = $HOSTS_FILE + ".tmp"
                            [System.IO.File]::WriteAllText($tmpPath, $content, [System.Text.Encoding]::UTF8)
                            Move-Item -Path $tmpPath -Destination $HOSTS_FILE -Force
                            $result = '{"success":true}'
                        } catch {
                            $resp.StatusCode = 500
                            $errMsg = ($_.Exception.Message -replace '"', "'")
                            $result = "{`"success`":false,`"error`":`"$errMsg`"}"
                        }
                    } else {
                        $resp.StatusCode = 400
                        $result = '{"success":false,"error":"Missing content field in request body"}'
                    }

                } elseif ($req.Url.AbsolutePath -eq "/launch-camera-viewer") {
                    if (-not $FFPLAY) {
                        $resp.StatusCode = 500
                        $result = '{"success":false,"error":"ffplay not found. Install FFmpeg: brew install ffmpeg"}'
                    } else {
                        # test mode: if tiny-test.mp4 exists in script dir, use it instead of live RTSP
                        $testVideo = Join-Path $SCRIPT_DIR "tiny-test.mp4"
                        $testMode  = Test-Path $testVideo

                        # build URL list for all 24 cameras (Away 1-12, Home 1-12)
                        $inputs = @()
                        for ($i = 0; $i -lt $CAM_ENV.CAM_AWAY.Count; $i++) {
                            if ($testMode) { $inputs += $testVideo }
                            else { $inputs += "rtsp://$($CAM_ENV.CAM_USER):$($CAM_ENV.CAM_PASS)@$($CAM_ENV.CAM_AWAY[$i])/axis-media/media.amp" }
                        }
                        for ($i = 0; $i -lt $CAM_ENV.CAM_HOME.Count; $i++) {
                            if ($testMode) { $inputs += $testVideo }
                            else { $inputs += "rtsp://$($CAM_ENV.CAM_USER):$($CAM_ENV.CAM_PASS)@$($CAM_ENV.CAM_HOME[$i])/axis-media/media.amp" }
                        }

                        # fixed viewer size — works on 1080p and above
                        $cellW  = 160   # 1920 / 12
                        $cellH  = 540   # 1080 / 2

                        # build and run a shell script mirroring cameras-all.sh (proven approach)
                        # Start-Process -ArgumentList array has cross-platform quoting issues
                        $shLines = @("#!/bin/bash")
                        for ($i = 0; $i -lt $inputs.Count; $i++) {
                            $col  = $i % 12
                            $row  = [int]($i / 12)
                            $left = $col * $cellW
                            $top  = $row * $cellH
                            $url  = $inputs[$i]
                            $loopArg = if ($testMode) { "-loop 1" } else { "" }
                            $shLines += "ffplay `"$url`" -an -noborder -alwaysontop -x $cellW -y $cellH -left $left -top $top $loopArg &"
                        }
                        $shLines += "exit 0"
                        $tmpScript = [System.IO.Path]::GetTempFileName() + ".sh"
                        [System.IO.File]::WriteAllText($tmpScript, ($shLines -join "`n"))
                        if (-not $IS_WINDOWS) { & chmod +x $tmpScript }

                        # send success response immediately before launching
                        $result = '{"success":true}'
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($result)
                        $resp.ContentLength64 = $bytes.Length
                        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                        $resp.Close()

                        # launch after response is sent
                        $proc = Start-Process -FilePath "/bin/bash" `
                            -ArgumentList $tmpScript -PassThru -ErrorAction SilentlyContinue
                        $script:viewerProcesses = @($proc)
                        continue
                    }

                } elseif ($req.Url.AbsolutePath -eq "/close-camera-viewer") {
                    # kill all tracked viewer processes
                    if ($script:viewerProcesses) {
                        foreach ($proc in $script:viewerProcesses) {
                            try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
                        }
                        $script:viewerProcesses = @()
                    }
                    # also kill any lingering ffplay processes (belt and braces)
                    Get-Process ffplay -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    $result = '{"success":true}'

                } elseif ($req.Url.AbsolutePath -eq "/viewer-status") {
                    $ffplayProcs = Get-Process ffplay -ErrorAction SilentlyContinue
                    $running     = ($null -ne $ffplayProcs -and @($ffplayProcs).Count -gt 0)
                    $result      = "{`"running`":$($running.ToString().ToLower())}"

                } elseif ($req.Url.AbsolutePath -eq "/exit") {
                    # write exit flag file — main loop will pick it up after current poll
                    $exitFlagPath = Join-Path $SCRIPT_DIR "kiosk-monitor.exit"
                    [System.IO.File]::WriteAllText($exitFlagPath, "exit")
                    $result = '{"success":true}'

                } else {
                    Write-Host "  [HTTP] 404 unmatched path: '$($req.Url.AbsolutePath)'"
                    $resp.StatusCode = 404
                    $result = '{"success":false,"error":"Not found: ' + $req.Url.AbsolutePath + '"}'
                }

                $bytes = [System.Text.Encoding]::UTF8.GetBytes($result)
                $resp.ContentLength64 = $bytes.Length
                $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                $resp.Close()
            } catch { }
        }
    }) | Out-Null

    $ps.BeginInvoke() | Out-Null
    Write-Host "  HTTP listener started on http://localhost:${HTTP_PORT}"
    return $ps
}

# --------------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------------
$pis    = Load-Hosts
$camEnv = Load-Env

if ($pis.Count -eq 0) {
    Write-Host "ERROR: No Pis found in $HOSTS_FILE" -ForegroundColor Red
    exit 1
}

Write-Host "=================================================="
Write-Host "  KCC Pi Kiosk Monitor"
Write-Host "  Polling every $POLL_SECS seconds"
Write-Host "  $($pis.Count) Pis, $($camEnv.CAM_HOME.Count + $camEnv.CAM_AWAY.Count) cameras"
Write-Host "  Output: $HTML_FILE"
Write-Host "  Platform: $(if ($IS_WINDOWS) { 'Windows' } else { 'macOS/Linux' })"
Write-Host "  SSH: $(if ($SSH) { $SSH } else { 'NOT FOUND' })"
Write-Host "  curl: $(if ($CURL) { $CURL } else { 'NOT FOUND' })"
Write-Host "  ffplay: $(if ($FFPLAY) { $FFPLAY } else { 'NOT FOUND -- install via: brew install ffmpeg' })"
if (-not $IS_WINDOWS) {
    Write-Host "  sshpass: $(if ($SSHPASS) { $SSHPASS } else { 'NOT FOUND -- install via: brew install sshpass' })"
}
Write-Host "  Press Ctrl+C to stop"
Write-Host "=================================================="
Write-Host ""

$listenerJob  = Start-HttpListener
$firstPoll    = $true
$lastSeenPis  = @{}   # keyed by IP, value = DateTime last reachable
$lastSeenCams = @{}   # keyed by IP, value = DateTime last reachable

$exitFlagPath = Join-Path $SCRIPT_DIR "kiosk-monitor.exit"

# clean up any stale exit flag from a previous run
if (Test-Path $exitFlagPath) { Remove-Item $exitFlagPath -Force -ErrorAction SilentlyContinue }

while ($true) {
    $pis = Load-Hosts
    Invoke-Poll $pis $camEnv $lastSeenPis $lastSeenCams

    if ($firstPoll) {
        $firstPoll = $false
        Write-Host "  Opening dashboard in browser..."
        if ($IS_WINDOWS) { Start-Process "http://localhost:${HTTP_PORT}" } else { & open "http://localhost:${HTTP_PORT}" }
    }

    # check exit flag — written by /exit HTTP endpoint
    if (Test-Path $exitFlagPath) {
        Remove-Item $exitFlagPath -Force -ErrorAction SilentlyContinue
        Write-Host "  Exit requested — stopping."
        exit 0
    }

    Start-Sleep -Seconds $POLL_SECS
}
