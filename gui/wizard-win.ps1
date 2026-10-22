# gui/wizard-win.ps1 - the Windows setup window of rdms-backup (WinForms, Windows PowerShell 5.1).
# `backup.sh wizard` runs it with RDMS_BACKUP_SH (the script), RDMS_BASH (Git's bash.exe) and BACKUP_CONF.
# Every decision lives in backup.sh: this window collects the answers, calls the script step by step (info,
# cloud-check, plan, init, setup --test-only, install, first-run) and shows its output. The password is stored from
# here with DPAPI (the same code as PS_CRED_WRITE in backup.sh), never put on a command line; the script then only
# tests the connection. Twin of gui/wizard-mac.swift: same steps, same texts.
# This file is ASCII on purpose: Windows PowerShell 5.1 reads a .ps1 without BOM as ANSI, so non-ASCII characters
# are built from [char] codes ($ELL, $ARROW).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ELL = [string][char]0x2026
$ARROW = [string][char]0x2192
$script:scriptPath = $env:RDMS_BACKUP_SH
$script:bashPath = $env:RDMS_BASH
if (-not $script:scriptPath -or -not $script:bashPath) {
    [Console]::Error.WriteLine("wizard-win: start it through 'backup.sh wizard'")
    exit 2
}
$script:exitCode = 0

# ------------------------------------------------------------------------------------------- running backup.sh
# bash runs hidden; its output goes to temp files (no pipes, so no reader threads): quick calls wait in a DoEvents
# loop, long ones are polled by a timer. Paths are passed with forward slashes (no trailing-backslash quoting traps).

function Quote-Arg([string]$s) {   # one argument for a Windows command line (MSVCRT/MSYS rules)
    if ($s -ne '' -and $s -notmatch '[\s"]') { return $s }
    return '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Start-Engine([string[]]$argv, [bool]$mergeErr) {
    $out = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
    $redir = if ($mergeErr) { '>"$RDMS_OUT" 2>&1' } else { '>"$RDMS_OUT" 2>"$RDMS_ERR"' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:bashPath
    $parts = @('-c', ('exec "$0" "$@" ' + $redir), $script:scriptPath) + $argv
    $psi.Arguments = ($parts | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['VERBOSE'] = '1'
    $psi.EnvironmentVariables['RDMS_OUT'] = $out.Replace('\', '/')
    $psi.EnvironmentVariables['RDMS_ERR'] = $err.Replace('\', '/')
    $p = [System.Diagnostics.Process]::Start($psi)
    return @{ Proc = $p; Out = $out; Err = $err; Pos = 0; Partial = '' }
}

function Read-All([string]$path) {   # UTF-8, tolerant of a writer that still holds the file
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try { $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); return $sr.ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

function Invoke-Engine([string[]]$argv) {   # run to completion, UI stays responsive; returns @{Code; Out; Err}
    $j = Start-Engine $argv $false
    while (-not $j.Proc.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
    $j.Proc.WaitForExit()
    $r = @{ Code = $j.Proc.ExitCode; Out = (Read-All $j.Out); Err = (Read-All $j.Err) }
    Remove-Item -LiteralPath $j.Out, $j.Err -Force -ErrorAction SilentlyContinue
    return $r
}

function Invoke-EngineJson([string[]]$argv) {
    $r = Invoke-Engine $argv
    if ($r.Code -ne 0) { return $null }
    try { return ($r.Out | ConvertFrom-Json) } catch { return $null }
}

# streaming: one job at a time; the timer appends new lines to the log pane and calls OnExit with the exit code
$script:job = $null
function Start-Stream([string[]]$argv, [scriptblock]$onExit) {
    $script:job = Start-Engine $argv $true
    $script:job.OnExit = $onExit
    $script:streamTimer.Start()
}
function Poll-Stream {
    $j = $script:job; if (-not $j) { $script:streamTimer.Stop(); return }
    $exited = $j.Proc.HasExited
    $text = Read-All $j.Out
    if ($text.Length -gt $j.Pos) {
        $new = $j.Partial + $text.Substring($j.Pos); $j.Pos = $text.Length
        $lines = $new -split "`n"
        $j.Partial = $lines[-1]
        if ($lines.Count -gt 1) { foreach ($l in $lines[0..($lines.Count - 2)]) { Write-Log $l.TrimEnd("`r") } }
    }
    if ($exited) {
        $script:streamTimer.Stop()
        if ($j.Partial) { Write-Log $j.Partial.TrimEnd("`r") }
        $j.Proc.WaitForExit(); $code = $j.Proc.ExitCode
        Remove-Item -LiteralPath $j.Out, $j.Err -Force -ErrorAction SilentlyContinue
        $script:job = $null
        & $j.OnExit $code
    }
}

# the password, DPAPI-encrypted for this Windows user (same format as `backup.sh setup` writes)
function Store-Password([string]$pw) {
    $cred = [string]$script:info.cred_file
    if (-not $cred) { return $false }
    try {
        $dir = Split-Path -Parent $cred
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        ConvertTo-SecureString -String $pw -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath $cred -Encoding ASCII
        return (Test-Path -LiteralPath $cred)
    } catch { return $false }
}

# ------------------------------------------------------------------------------------------- state
$Steps = @('Welcome', 'Account', 'Folders', 'Summary', 'Password', 'Schedule and first backup', 'Done')
$script:info = $null
$script:step = 0
$script:addMode = $false
$script:user = '@rug.nl'
$script:folders = New-Object System.Collections.ArrayList
$script:plan = $null
$script:busy = $false
$script:nextBlocked = $false
$ErrorActionPreference = 'Continue'   # from here on an unexpected error is shown, not fatal inside an event handler

function Reload-Info {
    $script:info = Invoke-EngineJson @('info')
}
function Info([string]$k) { if ($script:info -and $script:info.$k) { return [string]$script:info.$k } return '' }
function Path-Fwd([string]$p) { return $p.Replace('\', '/').TrimEnd('/') }

# ------------------------------------------------------------------------------------------- the window
$fontUI = New-Object System.Drawing.Font('Segoe UI', 9.75)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'RDMS backup setup'
$form.ClientSize = New-Object System.Drawing.Size(820, 560)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = $fontUI
$form.AutoScaleMode = 'Font'

$side = New-Object System.Windows.Forms.Panel
$side.SetBounds(0, 0, 200, 560)
$side.BackColor = [System.Drawing.SystemColors]::ControlLight
$form.Controls.Add($side)
$stepLabels = @()
for ($i = 0; $i -lt $Steps.Count; $i++) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Steps[$i]; $l.AutoSize = $false; $l.SetBounds(20, 24 + 30 * $i, 175, 24)
    $side.Controls.Add($l); $stepLabels += $l
}

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$titleLabel.SetBounds(224, 18, 570, 34)
$form.Controls.Add($titleLabel)

$bodyBox = New-Object System.Windows.Forms.Panel
$bodyBox.SetBounds(224, 58, 572, 250)
$form.Controls.Add($bodyBox)

$spinner = New-Object System.Windows.Forms.ProgressBar
$spinner.Style = 'Marquee'; $spinner.MarqueeAnimationSpeed = 30
$spinner.SetBounds(224, 318, 60, 14); $spinner.Visible = $false
$form.Controls.Add($spinner)
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.SetBounds(224, 312, 572, 40)
$statusLabel.ForeColor = [System.Drawing.SystemColors]::GrayText
$form.Controls.Add($statusLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'; $logBox.WordWrap = $true
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.BackColor = [System.Drawing.SystemColors]::Window
$logBox.SetBounds(224, 358, 572, 140)
$form.Controls.Add($logBox)

$backButton = New-Object System.Windows.Forms.Button
$backButton.Text = 'Back'; $backButton.SetBounds(600, 514, 90, 30)
$form.Controls.Add($backButton)
$nextButton = New-Object System.Windows.Forms.Button
$nextButton.Text = 'Continue'; $nextButton.SetBounds(706, 514, 90, 30)
$form.Controls.Add($nextButton)
$form.AcceptButton = $nextButton

$script:streamTimer = New-Object System.Windows.Forms.Timer
$script:streamTimer.Interval = 200
$script:streamTimer.Add_Tick({ Poll-Stream })
$script:tailTimer = New-Object System.Windows.Forms.Timer
$script:tailTimer.Interval = 2000
$script:tailTimer.Add_Tick({ Tail-Log })

# step widgets
$script:modeButtons = @()
$script:addressField = $null
$script:folderList = $null
$script:pw1 = $null
$script:pw2 = $null

# ------------------------------------------------------------------------------------------- helpers
function Write-Log([string]$line) { $logBox.AppendText($line + "`r`n") }
function Clear-Log { $logBox.Clear() }
function Set-Status([string]$s) { $statusLabel.Text = $s }
function Alert([string]$text, [string]$informative = '', [string]$buttons = 'OK', [string]$icon = 'Information') {
    $msg = if ($informative) { "$text`n`n$informative" } else { $text }
    return [string][System.Windows.Forms.MessageBox]::Show($form, $msg, 'RDMS backup setup', $buttons, $icon)
}

function Set-Busy([bool]$b) {
    $script:busy = $b
    Refresh-Buttons
}
function Refresh-Buttons {
    $s = $Steps[$script:step]
    $backOk = @('Account', 'Folders', 'Summary', 'Password') -contains $s
    if ($s -eq 'Folders' -and $script:addMode) { $backOk = $false }
    $backButton.Enabled = (-not $script:busy) -and $backOk
    $nextButton.Enabled = (-not $script:busy) -and (-not $script:nextBlocked)
    $spinner.Visible = $script:busy
    if ($script:busy) { $statusLabel.Left = 292; $statusLabel.Width = 504 } else { $statusLabel.Left = 224; $statusLabel.Width = 572 }
}

function New-Para([string]$text, [int]$top, [int]$height = 60) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $false; $l.SetBounds(0, $top, 566, $height)
    return $l
}
function Set-Body([System.Windows.Forms.Control[]]$controls) {
    $bodyBox.Controls.Clear()
    foreach ($c in $controls) { $bodyBox.Controls.Add($c) }
}

# ------------------------------------------------------------------------------------------- steps
function Show-Step([int]$s) {
    $script:step = $s
    for ($i = 0; $i -lt $stepLabels.Count; $i++) {
        $style = if ($i -eq $s) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
        $stepLabels[$i].Font = New-Object System.Drawing.Font('Segoe UI', 9.75, $style)
        $stepLabels[$i].ForeColor = if ($i -le $s) { [System.Drawing.SystemColors]::ControlText } else { [System.Drawing.SystemColors]::GrayText }
    }
    $titleLabel.Text = $Steps[$s]
    Set-Status ''
    $nextButton.Text = 'Continue'
    $script:nextBlocked = $false
    $logBox.Visible = $s -ge 4
    switch ($Steps[$s]) {
        'Welcome' { Show-Welcome }
        'Account' { Show-Account }
        'Folders' { Show-Folders }
        'Summary' { Show-Summary }
        'Password' { Show-Password }
        'Schedule and first backup' { Show-Schedule }
        'Done' { Show-Done }
    }
    Refresh-Buttons
}

function Show-Welcome {
    $ctl = @(New-Para ("This sets up an automatic backup of one or more folders to your RUG research storage (RDMS).`n`n" +
        "It runs by itself at 3, 11, 15 and 19 h, keeps earlier versions of changed files for 90 days, checks after " +
        "every run that everything arrived, and tells you when something is wrong.`n`n" +
        "You will be asked for your RUG address, the folder(s), and your password (typed here, stored only on this computer).") 0 120)
    $script:modeButtons = @()
    $missing = @()
    if ($script:info -and $script:info.missing) { $missing = @($script:info.missing) }
    if (-not $script:info) {
        $ctl += New-Para "Could not read the settings from backup.sh. Run 'bash backup.sh info' in Git Bash to see why." 130 60
        $script:nextBlocked = $true
    } elseif ($missing.Count -gt 0) {
        $ctl += New-Para ("Missing on this computer: " + ($missing -join ', ') + ".`nInstall them first: paste into a terminal:   " +
            "winget install Rclone.Rclone jqlang.jq Python.Python.3.12`nThen start the setup again.") 130 70
        $script:nextBlocked = $true
    } elseif ($script:info.config_exists) {
        $several = [bool]$script:info.several_folders
        $ctl += New-Para ("A backup is already set up: " + (Info 'name') + " (" + (Info 'local_dir') + " $ARROW " + (Info 'remote') + ").") 128 40
        $add = New-Object System.Windows.Forms.RadioButton
        $add.Text = 'Add folders to it'; $add.SetBounds(0, 170, 566, 22); $add.Enabled = $several
        $replace = New-Object System.Windows.Forms.RadioButton
        $replace.Text = 'Replace it and start over (a different folder choice moves the backup to a new place on the server and uploads again)'
        $replace.SetBounds(0, 194, 566, 38)
        $quit = New-Object System.Windows.Forms.RadioButton
        $quit.Text = 'Keep it and quit'; $quit.SetBounds(0, 234, 566, 22)
        if ($several) { $add.Checked = $true } else { $replace.Checked = $true }
        $script:modeButtons = @($add, $replace, $quit)
        $ctl += $script:modeButtons
    }
    Set-Body $ctl
}

function Show-Account {
    $script:addressField = New-Object System.Windows.Forms.TextBox
    $script:addressField.Text = $script:user; $script:addressField.SetBounds(0, 30, 360, 24)
    Set-Body @((New-Para 'Your RUG address:' 0 24), $script:addressField)
    $script:addressField.Select(); $script:addressField.SelectionStart = 0
}

function Show-Folders {
    $hint = if ($script:addMode) { "Folders inside " + (Info 'local_dir') + " can be added to this backup." }
            else { 'Documents is the usual choice. Several folders become one backup: add them one at a time.' }
    $script:folderList = New-Object System.Windows.Forms.ListBox
    $script:folderList.SetBounds(0, 46, 566, 150); $script:folderList.SelectionMode = 'MultiExtended'
    foreach ($f in $script:folders) { [void]$script:folderList.Items.Add($f) }
    $addB = New-Object System.Windows.Forms.Button
    $addB.Text = "Add folder$ELL"; $addB.SetBounds(0, 206, 110, 28); $addB.Add_Click({ Add-Folder })
    $remB = New-Object System.Windows.Forms.Button
    $remB.Text = 'Remove'; $remB.SetBounds(118, 206, 90, 28); $remB.Add_Click({ Remove-Folder })
    Set-Body @((New-Para $hint 0 40), $script:folderList, $addB, $remB)
}

function Show-Summary {
    $fs = @($script:plan.folders)
    $lines = @()
    if ($fs.Count -gt 1) { $lines += "Folders:`n  " + ($fs -join "`n  "); $lines += "Backed up as parts of " + $script:plan.local_dir }
    else { $lines += "Folder:  " + $fs[0] }
    $lines += "Account:  $($script:user)"
    $lines += "On the server:  $($script:plan.remote_path)"
    $lines += 'Runs at:  3, 11, 15, 19 h'
    $lines += "`nContinue writes the configuration. Next comes your password."
    Set-Body @(New-Para ($lines -join "`n") 0 240)
}

function Show-Password {
    $script:pw1 = New-Object System.Windows.Forms.TextBox
    $script:pw1.UseSystemPasswordChar = $true; $script:pw1.SetBounds(0, 46, 360, 24)
    $script:pw2 = New-Object System.Windows.Forms.TextBox
    $script:pw2.UseSystemPasswordChar = $true; $script:pw2.SetBounds(0, 110, 360, 24)
    Set-Body @((New-Para ("WebDAV password for " + (Info 'user') + " (stored encrypted for your Windows account, used only by the backup):") 0 40),
        $script:pw1, (New-Para 'Once more, to rule out a typo:' 84 22), $script:pw2)
    Clear-Log
    $script:pw1.Select()
}

function Show-Schedule {
    Set-Body @(New-Para "Installing the hourly schedule and starting the first backup$ELL" 0 30)
    $nextButton.Text = 'Finish'
    Run-Schedule
}

function Show-Done {
    Set-Body @(New-Para ("Done. The first backup runs in the background; with many files it takes hours, later runs " +
        "are quick. You can close this window.`n`nFrom now on it runs by itself. You hear from it when something is wrong, " +
        "and once a day at 3 am that all is well. In a terminal, 'backup.sh status' shows its health.") 0 140)
    $nextButton.Text = 'Close'
}

# ------------------------------------------------------------------------------------------- actions
function Do-Back {
    switch ($Steps[$script:step]) {
        'Account' { Show-Step 0 }
        'Folders' { Show-Step 1 }
        'Summary' { Show-Step 2 }
        'Password' { Show-Step 3 }
    }
}

function Do-Next {
    if ($script:busy) { return }
    switch ($Steps[$script:step]) {
        'Welcome' {
            if ($script:modeButtons.Count -gt 0) {
                if ($script:modeButtons[2].Checked) { $form.Close(); return }
                $script:addMode = $script:modeButtons[0].Checked
            }
            if ($script:addMode) { Show-Step 2 } else { Show-Step 1 }
        }
        'Account' {
            $script:user = $script:addressField.Text.Trim()
            if ($script:user -notmatch '^[A-Za-z0-9._%+-]*[A-Za-z0-9_%+-]@rug\.nl$') {
                [void](Alert "'$($script:user)' does not look like a RUG address." 'Expected name@rug.nl.' 'OK' 'Warning'); return
            }
            Show-Step 2
        }
        'Folders' {
            if ($script:folders.Count -eq 0) { [void](Alert 'Choose at least one folder.'); return }
            if ($script:addMode) { Add-FoldersAndFinish; return }
            $argv = @('plan'); foreach ($f in $script:folders) { $argv += @('--folder', $f) }
            Set-Busy $true; Set-Status "Planning$ELL"
            $r = Invoke-Engine $argv
            Set-Busy $false; Set-Status ''
            $p = $null; if ($r.Code -eq 0) { try { $p = $r.Out | ConvertFrom-Json } catch { $p = $null } }
            if (-not $p) { [void](Alert 'Could not plan the backup.' ($r.Out + $r.Err) 'OK' 'Error'); return }
            $script:plan = $p
            Show-Step 3
        }
        'Summary' {
            $argv = @('init', '--user', $script:user, '--remote-path', [string]$script:plan.remote_path, '--force', '--quiet')
            foreach ($f in @($script:plan.folders)) { $argv += @('--folder', $f) }
            Set-Busy $true; Set-Status "Writing the configuration$ELL"
            $r = Invoke-Engine $argv
            if ($r.Code -ne 0) { Set-Busy $false; Set-Status ''; [void](Alert 'Could not write the configuration.' ($r.Out + $r.Err) 'OK' 'Error'); return }
            Reload-Info
            Set-Busy $false
            Show-Step 4
        }
        'Password' { Store-AndTest }
        'Schedule and first backup' { $script:tailTimer.Stop(); Show-Step 6 }
        'Done' { $form.Close() }
    }
}

function Add-Folder {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.ShowNewFolderButton = $false
    $base = Path-Fwd (Info 'local_dir')
    if ($script:addMode) { $d.Description = "Choose a folder inside $base" } else { $d.Description = 'Choose a folder to back up' }
    $start = if ($script:addMode -or $script:folders.Count -eq 0) { $base } else { Split-Path -Parent $script:folders[$script:folders.Count - 1] }
    if ($start) { $d.SelectedPath = $start.Replace('/', '\') }
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $path = Path-Fwd $d.SelectedPath
    foreach ($f in $script:folders) { if ($f -ieq $path) { return } }
    if ($script:addMode -and -not $path.StartsWith($base + '/', [StringComparison]::OrdinalIgnoreCase)) {
        [void](Alert "$path is outside $base." ("It cannot be added to this backup. Including it means a new layout on the server: start the setup over " +
            "(uploads again), or set up a second backup with 'backup.sh -c <name> wizard'.") 'OK' 'Warning')
        return
    }
    Set-Busy $true; Set-Status "Checking $path$ELL"
    $c = Invoke-Engine @('cloud-check', $path)
    Set-Busy $false; Set-Status ''
    if ($c.Code -eq 0) {
        $root = $c.Out.Trim()
        $answer = Alert "$path lies inside a cloud-synced location ($root)." ("Files that exist only in the cloud would be downloaded by every run, " +
            "and files already in the cloud gain little from a second copy.`n`nYes: use it anyway.`nNo: leave it out.") 'YesNo' 'Warning'
        if ($answer -ne 'Yes') { return }
    }
    [void]$script:folders.Add($path)
    [void]$script:folderList.Items.Add($path)
}

function Remove-Folder {
    $sel = @($script:folderList.SelectedItems | ForEach-Object { [string]$_ })
    foreach ($s in $sel) { $script:folders.Remove($s); $script:folderList.Items.Remove($s) }
}

function Store-AndTest {
    $a = $script:pw1.Text; $b = $script:pw2.Text
    if (-not $a) { [void](Alert 'Please type the password.'); return }
    if ($a -ne $b) {
        [void](Alert 'The two entries differ.' 'Please type the password again in both fields.' 'OK' 'Warning')
        $script:pw2.Text = ''; $script:pw2.Select(); return
    }
    Set-Busy $true
    Clear-Log
    Set-Status "Storing the password$ELL"
    $ok = Store-Password $a
    $script:pw1.Text = ''; $script:pw2.Text = ''; $a = $null; $b = $null
    if (-not $ok) {
        Set-Busy $false
        Set-Status ("Could not store the password in " + (Info 'cred_file') + ".")
        return
    }
    Set-Status ("Testing the connection as " + (Info 'user') + $ELL)
    Start-Stream @('setup', '--test-only') {
        param($code)
        Set-Busy $false
        if ($code -eq 0) { Show-Step 5 }
        else {
            Set-Status ("Could not connect as " + (Info 'user') + ". Wrong password? Type it again. Wrong address? Go Back twice to correct it.")
            $script:pw1.Select()
        }
    }
}

function Run-Schedule {
    Set-Busy $true
    Clear-Log
    Set-Status "Installing the schedule$ELL"
    Start-Stream @('install') {
        param($code)
        if ($code -ne 0) { Set-Busy $false; Set-Status "Installing the schedule failed; see the log. 'backup.sh install' in a terminal shows more."; return }
        Set-Status "Starting the first backup$ELL"
        Start-Stream @('first-run') {
            param($code)
            Set-Busy $false
            if ($code -ne 0) { Set-Status 'Could not start the first backup; see the log.'; return }
            Set-Status 'The first backup is running. Its progress appears below; you may finish now, it continues in the background.'
            Start-Tail
        }
    }
}

function Add-FoldersAndFinish {
    $argv = @('init', '--add', '--quiet'); foreach ($f in $script:folders) { $argv += @('--folder', $f) }
    Set-Busy $true; Set-Status "Updating the folder list$ELL"
    $r = Invoke-Engine $argv
    if ($r.Code -ne 0) { Set-Busy $false; Set-Status ''; [void](Alert 'Could not update the folder list.' ($r.Out + $r.Err) 'OK' 'Error'); return }
    Reload-Info
    $logBox.Visible = $true
    Clear-Log
    Set-Status "Starting a full pass to pick up the new folder(s)$ELL"
    Start-Stream @('first-run') {
        param($code)
        Set-Busy $false
        if ($code -ne 0) { Set-Status 'Could not start the run; see the log. The folders are in the list and the next scheduled run picks them up.'; return }
        Start-Tail
        Show-Step 6
    }
}

function Start-Tail { Tail-Log; $script:tailTimer.Start() }
function Tail-Log {
    $path = (Info 'log_dir') + '/latest/run.log'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $text = Read-All $path
    $lines = @($text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    if ($lines.Count -gt 14) { $lines = $lines[($lines.Count - 14)..($lines.Count - 1)] }
    $logBox.Text = ($lines -join "`r`n")
    $logBox.SelectionStart = $logBox.TextLength; $logBox.ScrollToCaret()
}

$backButton.Add_Click({ Do-Back })
$nextButton.Add_Click({ Do-Next })
$form.Add_Shown({
    $form.TopMost = $true; $form.Activate(); $form.TopMost = $false
    Set-Busy $true; Set-Status "Reading the settings$ELL"
    Reload-Info
    Set-Busy $false
    Show-Step 0
})
$form.Add_FormClosing({
    $script:streamTimer.Stop(); $script:tailTimer.Stop()
    if ($script:job -and -not $script:job.Proc.HasExited) { try { $script:job.Proc.Kill() } catch { } }
})

try {
    [void]$form.ShowDialog()
} catch {
    [Console]::Error.WriteLine("wizard-win: $_")
    $script:exitCode = 2
}
exit $script:exitCode
