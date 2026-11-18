# ================================================================
#  DLP_Kriva Agent  —  हर Windows PC पर चलता है (Win7 SP1 .NET4.8 → Win11)
#  काम: register + device info भेजना, panel से policy लेना व लागू करना,
#       file/USB/clipboard/login logs, screenshots, remote commands।
#  कानूनी: सिर्फ़ company-owned PC पर, employee की सहमति के साथ।
# ================================================================

# ===== ये lines download के समय अपने-आप भर जाती हैं =====
$ServerUrl    = "http://dlp.mitalinfosys.info"      # server address
$EnrollSecret = "PASTE_YOUR_ENROLL_SECRET_HERE"     # client का enroll secret
$BuildToken   = ""                                  # इस download की baked default policy
# =======================================================

$ErrorActionPreference = 'SilentlyContinue'
$AgentVer    = "2.0"
$PollSeconds = 20
$DataDir     = "C:\ProgramData\DLPAgent"
$StateFile   = Join-Path $DataDir "agent.json"
$ShotFile    = Join-Path $DataDir "shot.jpg"
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# ===== HTTP + JSON helpers — Windows 7 के PowerShell 2.0 तक चलते हैं =====
# (पुराने Windows में Invoke-RestMethod / ConvertTo-Json / ConvertFrom-Json नहीं होते,
#  इसलिए .NET HttpWebRequest + JavaScriptSerializer इस्तेमाल करते हैं — हर PC पर register होता है।)
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}  # TLS1.2
try { Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue } catch {}
$script:JSS = $null
try { $script:JSS = New-Object System.Web.Script.Serialization.JavaScriptSerializer; $script:JSS.MaxJsonLength = 67108864 } catch {}

# debug log — हर register/policy attempt यहाँ लिखता है, ताकि कोई PC panel में न दिखे तो पता चले
$script:DbgFile = Join-Path $DataDir 'debug.log'
function Log-Dbg($msg) {
  try { Add-Content -Path $script:DbgFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "  " + $msg) -ErrorAction SilentlyContinue } catch {}
}

function To-Json($obj) {
  if ($script:JSS) { try { return $script:JSS.Serialize($obj) } catch {} }
  try { return ($obj | ConvertTo-Json -Compress -Depth 6) } catch {}
  return '{}'
}
# JSS Dictionary/object[] को PSObject में बदलो ताकि $r.ok / $p.policy.usb_block हर PowerShell में चले
function To-PSObj($o) {
  if ($o -is [System.Collections.IDictionary]) {
    $h = @{}; foreach ($k in $o.Keys) { $h["$k"] = (To-PSObj $o[$k]) }
    return (New-Object psobject -Property $h)
  } elseif ($o -is [object[]] -or $o -is [System.Collections.ArrayList]) {
    $arr = @(); foreach ($i in $o) { $arr += (To-PSObj $i) }; return $arr
  }
  return $o
}
function From-Json($text) {
  if (-not $text) { return $null }
  if ($script:JSS) { try { return (To-PSObj ($script:JSS.DeserializeObject($text))) } catch {} }
  try { return ($text | ConvertFrom-Json) } catch {}
  return $null
}
# method GET/POST; headers hashtable; bodyObj (POST के लिए) — parsed object लौटाता है
function Http-Json($method, $url, $headers, $bodyObj) {
  try {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = $method; $req.Timeout = 25000; $req.ContentType = 'application/json'
    if ($headers) { foreach ($k in $headers.Keys) { try { $req.Headers.Add($k, [string]$headers[$k]) } catch {} } }
    if ($method -ne 'GET' -and $bodyObj -ne $null) {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes((To-Json $bodyObj))
      $req.ContentLength = $bytes.Length
      $st = $req.GetRequestStream(); $st.Write($bytes,0,$bytes.Length); $st.Close()
    }
    $resp = $req.GetResponse()
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $out = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
    return From-Json $out
  } catch {
    Log-Dbg ("HTTP FAIL " + $method + " " + $url + " :: " + $_.Exception.Message)
    return $null
  }
}

# ===== agent-config.json से server/secret/token पढ़ो =====
# एक ही universal DLP_Kriva.exe हर client के लिए चलती है — पहचान उसके साथ रखी
# agent-config.json से आती है (EXE के पास या C:\ProgramData\DLPAgent में)। इससे
# हर client के लिए अलग EXE compile करने की ज़रूरत नहीं।
try {
  $selfDir = $DataDir
  try { $mp = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName; if ($mp) { $selfDir = Split-Path -Parent $mp } } catch {}
  foreach ($cp in @((Join-Path $selfDir 'agent-config.json'), (Join-Path $DataDir 'agent-config.json'))) {
    if ($cp -and (Test-Path $cp)) {
      $cfg = From-Json (Get-Content $cp -Raw)
      if ($cfg.server)        { $ServerUrl    = [string]$cfg.server }
      if ($cfg.enroll_secret) { $EnrollSecret = [string]$cfg.enroll_secret }
      if ($cfg.build_token)   { $BuildToken   = [string]$cfg.build_token }
      # config को DataDir में रख लो ताकि SYSTEM task बाद में भी पढ़ सके
      try { if ($cp -ne (Join-Path $DataDir 'agent-config.json')) { Copy-Item $cp (Join-Path $DataDir 'agent-config.json') -Force } } catch {}
      break
    }
  }
} catch {}

$global:LogQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))

function Get-MachineId {
  $g = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
  if (-not $g) { $g = $env:COMPUTERNAME }
  return $g
}

# ---- device / network inventory ----
function Get-DeviceInfo {
  $mac=''; $ip=''; $ip6=''
  try {
    $na = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE" | Select-Object -First 1
    if ($na) { $mac = $na.MACAddress; $ip = ($na.IPAddress | Where-Object { $_ -match '\.' } | Select-Object -First 1) }
    $ip6 = ($na.IPAddress | Where-Object { $_ -match ':' } | Select-Object -First 1)
  } catch {}
  $win=''
  try { $os = Get-CimInstance Win32_OperatingSystem; $win = "$($os.Caption) ($($os.Version))" } catch {}
  return @{
    mac = $mac; local_ip = $ip; ipv6 = $ip6; win_ver = $win
    os_user = "$env:USERDOMAIN\$env:USERNAME"; agent_ver = $AgentVer
  }
}

function Register-Agent {
  if (Test-Path $StateFile) {
    $s = From-Json (Get-Content $StateFile -Raw)
    if ($s -and $s.api_key) { return [string]$s.api_key }
  }
  $d = Get-DeviceInfo
  $body = @{ enroll_secret=$EnrollSecret; pc_name=$env:COMPUTERNAME; machine_id=(Get-MachineId);
             build_token=$BuildToken; mac=$d.mac; win_ver=$d.win_ver; local_ip=$d.local_ip;
             ipv6=$d.ipv6; os_user=$d.os_user; agent_ver=$d.agent_ver }
  Log-Dbg ("REGISTER -> " + $ServerUrl + "  secret=" + $EnrollSecret.Substring(0,[Math]::Min(4,$EnrollSecret.Length)) + "...  pc=" + $env:COMPUTERNAME)
  $r = Http-Json 'POST' "$ServerUrl/api/register.php" $null $body
  if ($r -and $r.ok -and $r.api_key) {
    try { (To-Json @{ api_key=[string]$r.api_key }) | Set-Content $StateFile } catch {}
    Log-Dbg ("REGISTER OK  status=" + $r.status)
    return [string]$r.api_key
  }
  Log-Dbg ("REGISTER FAIL  resp.ok=" + $(if($r){$r.ok}else{'null'}) + "  err=" + $(if($r){$r.error}else{'no response (network/URL?)'}))
  return $null
}

# ---- File activity watchers ----
$script:OnChange = {
  $e=$Event.SourceEventArgs; $q=$Event.MessageData
  $t = switch ("$($e.ChangeType)") { 'Created' {'file_created'} 'Deleted' {'file_deleted'} default {'file_changed'} }
  $q.Enqueue(@{ type=$t; message=[System.IO.Path]::GetFileName($e.FullPath); path_from=$e.FullPath; path_to='' })
}
$script:OnRename = {
  $e=$Event.SourceEventArgs; $q=$Event.MessageData
  $q.Enqueue(@{ type='file_renamed'; message=[System.IO.Path]::GetFileName($e.FullPath); path_from=$e.OldFullPath; path_to=$e.FullPath })
}
function Start-FileWatchers {
  $subs=@('Desktop','Documents','Downloads')
  Get-ChildItem 'C:\Users' -Directory | ForEach-Object {
    foreach ($s in $subs) {
      $p = Join-Path $_.FullName $s
      if (Test-Path $p) {
        $fsw = New-Object System.IO.FileSystemWatcher $p
        $fsw.IncludeSubdirectories=$true; $fsw.EnableRaisingEvents=$true
        Register-ObjectEvent $fsw Created -Action $script:OnChange -MessageData $global:LogQueue | Out-Null
        Register-ObjectEvent $fsw Deleted -Action $script:OnChange -MessageData $global:LogQueue | Out-Null
        Register-ObjectEvent $fsw Renamed -Action $script:OnRename -MessageData $global:LogQueue | Out-Null
      }
    }
  }
}

# ---- USB storage block (USBSTOR Start: 4=block,3=allow) ----
$script:UsbApplied = -1
function Apply-UsbPolicy($blocked) {
  $val = if ($blocked -eq 1) {4} else {3}
  if ($script:UsbApplied -eq $val) { return }
  Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name Start -Value $val
  $script:UsbApplied = $val
  $txt = if ($blocked -eq 1) {'USB blocked'} else {'USB allowed'}
  $global:LogQueue.Enqueue(@{ type='usb_policy'; message=$txt; path_from=''; path_to='' })
}

# ---- Windows Update block (wuauserv) ----
$script:WuApplied = -1
function Apply-WinUpdate($block) {
  if ($script:WuApplied -eq $block) { return }
  if ($block -eq 1) { Set-Service wuauserv -StartupType Disabled; Stop-Service wuauserv -Force }
  else { Set-Service wuauserv -StartupType Manual }
  $script:WuApplied = $block
}

# ---- USB insert detection ----
$script:KnownDrives=@()
function Check-UsbInsert {
  $drives = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2" | Select-Object -ExpandProperty DeviceID)
  foreach ($d in $drives) {
    if ($script:KnownDrives -notcontains $d) { $global:LogQueue.Enqueue(@{ type='usb_inserted'; message="USB drive $d plugged in"; path_from=$d; path_to='' }) }
  }
  $script:KnownDrives = $drives
}

# ---- Screenshot (savedesktop → JPEG) ----
# सिर्फ़ तब भेजता है जब screen में बदलाव हुआ हो (यानी कोई काम चल रहा हो)।
# अगर PC idle है / कुछ नहीं बदला, तो वही screenshot दोबारा नहीं भेजता।
$script:LastShotHash = ''
function Capture-Screen($apikey, $watermark) {
  try {
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    # watermark लगाने से पहले raw image का hash — ताकि timestamp hash न बदले
    $msRaw = New-Object System.IO.MemoryStream
    $bmp.Save($msRaw, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $rawBytes = $msRaw.ToArray(); $msRaw.Dispose()
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = [BitConverter]::ToString($md5.ComputeHash($rawBytes))
    if ($hash -eq $script:LastShotHash) { $g.Dispose(); $bmp.Dispose(); return }  # screen में कोई change नहीं — skip
    $script:LastShotHash = $hash
    if ($watermark -eq 1) {
      $f = New-Object System.Drawing.Font('Arial',12)
      $txt = "$env:COMPUTERNAME  $env:USERNAME  " + (Get-Date -Format 'dd-MM HH:mm:ss')
      $g.DrawString($txt, $f, [System.Drawing.Brushes]::Yellow, 8, 8)
    }
    $bmp.Save($ShotFile, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $g.Dispose(); $bmp.Dispose()
    $bytes = [IO.File]::ReadAllBytes($ShotFile)
    $b64 = [Convert]::ToBase64String($bytes)
    Http-Json 'POST' "$ServerUrl/api/screenshot.php" @{ 'X-API-Key'=$apikey } @{ image=$b64; note='interval' } | Out-Null
  } catch {}
}

# ---- Remote commands ----
function Run-Command($c) {
  switch ($c.cmd) {
    'lock'    { rundll32.exe user32.dll,LockWorkStation }
    'logout'  { shutdown /l /f }
    'restart' { shutdown /r /t 5 /f }
    'unlock'  { Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name Start -Value 3 }
  }
  $global:LogQueue.Enqueue(@{ type='remote_cmd'; message="command: $($c.cmd)"; path_from=''; path_to='' })
}

# ---- send queued logs ----
function Flush-Logs($apikey, $fileMonitor) {
  if ($global:LogQueue.Count -eq 0) { return }
  $items=@()
  while ($global:LogQueue.Count -gt 0 -and $items.Count -lt 100) {
    $it = $global:LogQueue.Dequeue()
    if ($fileMonitor -eq 0 -and $it.type -like 'file_*') { continue }
    $items += $it
  }
  if ($items.Count -eq 0) { return }
  Http-Json 'POST' "$ServerUrl/api/log.php" @{ 'X-API-Key'=$apikey } @{ logs=$items } | Out-Null
}

# ===== Setup wizard — double-click par "Next" screen, 3 options =====
# 1) Config file (.json) upload  2) Token (Enroll Code) paste  3) Email/Username
#    + Password se login (portal khud token nikal leta hai). Lautata hai hashtable
#    @{server; enroll_secret} ya $null (cancel). PS 2.0 (Win7) tak chalta hai.
function Show-SetupWizard {
  try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing } catch { return $null }
  $f = New-Object System.Windows.Forms.Form
  $f.Text = 'DLP_Kriva Setup'; $f.StartPosition = 'CenterScreen'
  $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
  $f.ClientSize = New-Object System.Drawing.Size(440, 300)
  $f.BackColor = [System.Drawing.Color]::White
  $hd = New-Object System.Windows.Forms.Label
  $hd.Text = 'Is PC ko kis tarah client se jodein?'; $hd.AutoSize = $false
  $hd.Location = New-Object System.Drawing.Point(18,14); $hd.Size = New-Object System.Drawing.Size(404,22)
  $hd.Font = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
  $f.Controls.Add($hd)
  # Option 1 — config file
  $r1 = New-Object System.Windows.Forms.RadioButton
  $r1.Text = '1) Config file (.json) upload karein'; $r1.Location = New-Object System.Drawing.Point(18,46)
  $r1.Size = New-Object System.Drawing.Size(404,22); $r1.Checked = $true; $f.Controls.Add($r1)
  # Option 2 — token paste
  $r2 = New-Object System.Windows.Forms.RadioButton
  $r2.Text = '2) Token (Enroll Code) paste karein'; $r2.Location = New-Object System.Drawing.Point(18,78)
  $r2.Size = New-Object System.Drawing.Size(404,22); $f.Controls.Add($r2)
  $tbTok = New-Object System.Windows.Forms.TextBox
  $tbTok.Location = New-Object System.Drawing.Point(40,102); $tbTok.Size = New-Object System.Drawing.Size(382,24)
  $tbTok.Enabled = $false; $f.Controls.Add($tbTok)
  # Option 3 — login
  $r3 = New-Object System.Windows.Forms.RadioButton
  $r3.Text = '3) Email/Username + Password se login'; $r3.Location = New-Object System.Drawing.Point(18,134)
  $r3.Size = New-Object System.Drawing.Size(404,22); $f.Controls.Add($r3)
  $lbU = New-Object System.Windows.Forms.Label
  $lbU.Text = 'Email / Username'; $lbU.Location = New-Object System.Drawing.Point(40,160); $lbU.Size = New-Object System.Drawing.Size(130,20)
  $f.Controls.Add($lbU)
  $tbU = New-Object System.Windows.Forms.TextBox
  $tbU.Location = New-Object System.Drawing.Point(176,158); $tbU.Size = New-Object System.Drawing.Size(246,24); $tbU.Enabled = $false; $f.Controls.Add($tbU)
  $lbP = New-Object System.Windows.Forms.Label
  $lbP.Text = 'Password'; $lbP.Location = New-Object System.Drawing.Point(40,188); $lbP.Size = New-Object System.Drawing.Size(130,20)
  $f.Controls.Add($lbP)
  $tbP = New-Object System.Windows.Forms.TextBox
  $tbP.Location = New-Object System.Drawing.Point(176,186); $tbP.Size = New-Object System.Drawing.Size(246,24); $tbP.UseSystemPasswordChar = $true; $tbP.Enabled = $false; $f.Controls.Add($tbP)
  # enable/disable fields with selection
  $sync = {
    $tbTok.Enabled = $r2.Checked
    $tbU.Enabled = $r3.Checked; $tbP.Enabled = $r3.Checked
  }
  $r1.Add_CheckedChanged($sync); $r2.Add_CheckedChanged($sync); $r3.Add_CheckedChanged($sync)
  # buttons
  $bn = New-Object System.Windows.Forms.Button
  $bn.Text = 'Next'; $bn.Location = New-Object System.Drawing.Point(258,250); $bn.Size = New-Object System.Drawing.Size(80,30)
  $f.Controls.Add($bn)
  $bc = New-Object System.Windows.Forms.Button
  $bc.Text = 'Cancel'; $bc.Location = New-Object System.Drawing.Point(342,250); $bc.Size = New-Object System.Drawing.Size(80,30)
  $bc.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $f.Controls.Add($bc); $f.CancelButton = $bc
  $script:WizResult = $null
  $bn.Add_Click({
    if ($r1.Checked) {
      $ofd = New-Object System.Windows.Forms.OpenFileDialog
      $ofd.Title = 'agent-config.json chunein'; $ofd.Filter = 'DLP config (*.json)|*.json|All files (*.*)|*.*'
      if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and (Test-Path $ofd.FileName)) {
        try { $cfg = From-Json (Get-Content $ofd.FileName -Raw) } catch { $cfg = $null }
        if ($cfg -and $cfg.enroll_secret) {
          $srv = if ($cfg.server) { [string]$cfg.server } else { $ServerUrl }
          $script:WizResult = @{ server = $srv; enroll_secret = [string]$cfg.enroll_secret }
          $f.DialogResult = [System.Windows.Forms.DialogResult]::OK; $f.Close()
        } else { [System.Windows.Forms.MessageBox]::Show('Config file me enroll_secret nahi mila.','DLP_Kriva',0,48) | Out-Null }
      }
    } elseif ($r2.Checked) {
      $code = ("" + $tbTok.Text).Trim()
      if ($code) { $script:WizResult = @{ server = $ServerUrl; enroll_secret = $code }; $f.DialogResult = [System.Windows.Forms.DialogResult]::OK; $f.Close() }
      else { [System.Windows.Forms.MessageBox]::Show('Token (Enroll Code) daalein.','DLP_Kriva',0,48) | Out-Null }
    } elseif ($r3.Checked) {
      $u = ("" + $tbU.Text).Trim(); $pw = [string]$tbP.Text
      if (-not $u -or -not $pw) { [System.Windows.Forms.MessageBox]::Show('Login aur password dono daalein.','DLP_Kriva',0,48) | Out-Null; return }
      $resp = $null
      try { $resp = Http-Json 'POST' "$ServerUrl/api/enroll_login.php" @{} @{ login=$u; password=$pw } } catch {}
      if ($resp -and $resp.ok -and $resp.enroll_secret) {
        $srv = if ($resp.server) { [string]$resp.server } else { $ServerUrl }
        $script:WizResult = @{ server = $srv; enroll_secret = [string]$resp.enroll_secret }
        $f.DialogResult = [System.Windows.Forms.DialogResult]::OK; $f.Close()
      } else {
        $em = if ($resp -and $resp.error) { [string]$resp.error } else { 'login fail — net/credentials check karein' }
        [System.Windows.Forms.MessageBox]::Show($em,'DLP_Kriva',0,48) | Out-Null
      }
    }
  })
  $null = $f.ShowDialog()
  return $script:WizResult
}

# ===== EXE double-click => khud install (koi .bat/powershell dikhega nahi) =====
# जब compiled DLP_Kriva.exe को कहीं से double-click करें: खुद को ProgramData में copy
# करके SYSTEM task बना देती और चालू कर देती है। Task से चलते वक़्त (ProgramData से) नीचे
# का agent loop चलता है। ps1+install-agent.bat वाला flow इससे अछूता रहता है।
$script:SelfPath = ''
try { $script:SelfPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch {}
$isExe  = $script:SelfPath -and ($script:SelfPath -match '\.exe$') -and ($script:SelfPath -notmatch '(?i)powershell|pwsh|cmd|conhost')
$inData = $script:SelfPath -and ((Split-Path -Parent $script:SelfPath) -ieq $DataDir)
if ($isExe -and -not $inData) {
  $admin = $false
  try { $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) } catch {}
  if (-not $admin) { try { Start-Process -FilePath $script:SelfPath -Verb RunAs } catch {}; exit }
  try {
    Copy-Item $script:SelfPath (Join-Path $DataDir 'DLP_Kriva.exe') -Force
    $dstCfg = Join-Path $DataDir 'agent-config.json'
    $srcCfg = Join-Path (Split-Path -Parent $script:SelfPath) 'agent-config.json'
    # --- Per-client identity (Enroll Code / token) ---------------------------
    # Priority: (1) agent-config.json EXE ke saath; (2) ProgramData me pehle se;
    # (3) EXE me baked EnrollSecret; (4) warna install ke waqt poochho —
    #     user ya to Enroll Code paste kare, ya config file (.json) chune.
    if (Test-Path $srcCfg) {
      Copy-Item $srcCfg $dstCfg -Force
      Log-Dbg "SELF-INSTALL config: sibling agent-config.json"
    } elseif (Test-Path $dstCfg) {
      Log-Dbg "SELF-INSTALL config: existing ProgramData agent-config.json"
    } elseif ($EnrollSecret -and ($EnrollSecret -ne 'PASTE_YOUR_ENROLL_SECRET_HERE')) {
      (To-Json @{ server = $ServerUrl; enroll_secret = $EnrollSecret; build_token = $BuildToken }) | Set-Content -Path $dstCfg -Encoding ASCII
      Log-Dbg "SELF-INSTALL config: baked EnrollSecret"
    } else {
      # Next wizard — 3 options (file / token paste / login)
      $wr = Show-SetupWizard
      if ($wr -and $wr.enroll_secret) {
        $srv = if ($wr.server) { [string]$wr.server } else { $ServerUrl }
        (To-Json @{ server = $srv; enroll_secret = [string]$wr.enroll_secret }) | Set-Content -Path $dstCfg -Encoding ASCII
        Log-Dbg "SELF-INSTALL config: via wizard"
      } else {
        try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('Setup cancel ho gaya. Token/config/login me se ek zaroori hai.','DLP_Kriva',0,48) | Out-Null } catch {}
        Log-Dbg "SELF-INSTALL abort: wizard cancelled"
        exit
      }
    }
    $tr = '"' + (Join-Path $DataDir 'DLP_Kriva.exe') + '"'
    schtasks /Create /TN 'DLPAgent' /TR $tr /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null
    schtasks /Run /TN 'DLPAgent' | Out-Null
    Log-Dbg "SELF-INSTALL done (exe)"
    try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('DLP_Kriva install ho gaya aur chalu ho gaya.' + [Environment]::NewLine + '~20 second me ye PC panel me dikhega.','DLP_Kriva',0,64) | Out-Null } catch {}
  } catch { Log-Dbg ("SELF-INSTALL fail :: " + $_.Exception.Message) }
  exit
}

# ================= MAIN =================
Log-Dbg ("AGENT START  ver=" + $AgentVer + "  server=" + $ServerUrl + "  self=" + $script:SelfPath)
Start-FileWatchers
$global:LogQueue.Enqueue(@{ type='login'; message="agent start — $env:USERNAME"; path_from=''; path_to='' })
$apikey = $null; $fileMonitor = 1; $lastShot = Get-Date '2000-01-01'
while ($true) {
  if (-not $apikey) { $apikey = Register-Agent }
  if ($apikey) {
    try {
      $p = Http-Json 'GET' "$ServerUrl/api/policy.php?pc=$env:COMPUTERNAME" @{ 'X-API-Key'=$apikey } $null
      if ($p -and $p.ok -and $p.active) {
        $pol = $p.policy
        Apply-UsbPolicy ([int]$pol.usb_block)
        Apply-WinUpdate ([int]$pol.block_win_update)
        $fileMonitor = [int]$pol.file_monitor
        # screenshots
        if ([int]$pol.screenshot -eq 1) {
          $iv = [int]$pol.screenshot_sec; if ($iv -lt 10) { $iv = 60 }
          if ((New-TimeSpan $lastShot (Get-Date)).TotalSeconds -ge $iv) { Capture-Screen $apikey ([int]$pol.screen_watermark); $lastShot = Get-Date }
        }
        # remote commands
        if ($p.commands) { foreach ($c in $p.commands) { Run-Command $c } }
      }
    } catch {}
    Check-UsbInsert
    Flush-Logs $apikey $fileMonitor
  }
  Start-Sleep -Seconds $PollSeconds
}
