<#
WITStream Connect installer for Windows Server (and Windows 10/11).

Installs WITStream Connect as the Windows service "WITStreamConnect", with
no Docker needed. Run in PowerShell opened with "Run as administrator":

    irm https://witstreamconnect.com/install.ps1 | iex

Safe to run again: it is also the update command. It stops the service,
installs the latest version and starts it again, keeping the existing
settings in C:\ProgramData\WITStream Connect.

Options (download the script first to use them):
    .\install.ps1 -Version v0.2.46     install a specific version
    .\install.ps1 -Port 3005           dashboard on another port
    .\install.ps1 -Uninstall           remove the service and program (settings and data are kept)
#>
param(
    [string]$Version = "latest",
    [int]$Port = 0,
    [switch]$Uninstall,
    # For the publishing workflow's own test: install this file instead of downloading.
    [string]$PackagePath = "",
    [string]$LicenceKey = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ServiceName = "WITStreamConnect"
$DisplayName = "WITStream Connect"
$ProgramDir = Join-Path $env:ProgramFiles "WITStream Connect"
$ProgramExe = Join-Path $ProgramDir "WITStreamConnect.exe"
$DataDir = Join-Path $env:ProgramData "WITStream Connect"
$ConfigFile = Join-Path $DataDir "witstream-config.json"
$LicenceServerUrl = if ($env:WITSTREAM_LICENCE_SERVER_URL) { $env:WITSTREAM_LICENCE_SERVER_URL } else { "https://licence.witstreamconnect.com" }
$Registry = if ($env:WITSTREAM_REGISTRY) { $env:WITSTREAM_REGISTRY } else { "https://registry.witstreamconnect.com" }
$Repository = "witstream-connect-windows"
$PackageName = "WITStream-Connect-windows.exe"

function Info($text) { Write-Host $text }
function Fail($text) { Write-Host "Error: $text" -ForegroundColor Red; exit 1 }

Info "WITStream Connect$([char]0x00AE) installer for Windows"
Info "-------------------------------------"

# 1. Administrator rights are needed to install a service and a firewall rule.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Please run this in PowerShell opened as administrator: right-click PowerShell and choose 'Run as administrator', then run the command again."
}

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($Uninstall) {
    if ($existing) {
        Info "Stopping and removing the service..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        & sc.exe delete $ServiceName | Out-Null
    }
    Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (Test-Path $ProgramDir) { Remove-Item -Recurse -Force $ProgramDir }
    Info "WITStream Connect has been removed. Settings and data are kept in $DataDir; delete that folder to remove them too."
    exit 0
}

# 2. The licence key: read from the existing settings on an update, asked
#    for once on a first install (hidden as it is typed or pasted).
if (-not $LicenceKey -and (Test-Path $ConfigFile)) {
    $LicenceKey = (Get-Content $ConfigFile -Raw | ConvertFrom-Json).licence.licenceKey
}
if (-not $LicenceKey) {
    $secure = Read-Host "Licence key (from your WITStream Connect account, hidden as you paste it)" -AsSecureString
    $LicenceKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    if (-not $LicenceKey) { Fail "No licence key entered." }
    Info "Licence key received (ending $($LicenceKey.Substring([Math]::Max(0, $LicenceKey.Length - 4))))."
}

# 3. Download the program from the WITStream Connect registry. The licence
#    key is the sign-in: the Licence Server checks it and issues a
#    15-minute download pass.
$download = Join-Path $env:TEMP "WITStreamConnect-download.exe"
if ($PackagePath) {
    Copy-Item $PackagePath $download -Force
} else {
    Info "Signing in to the WITStream Connect registry..."
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("licence:$LicenceKey"))
    try {
        $token = (Invoke-RestMethod -Uri "$LicenceServerUrl/registry/token?service=registry.witstreamconnect.com&scope=repository:${Repository}:pull" -Headers @{ Authorization = "Basic $basic" }).token
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { Fail "That licence key wasn't accepted. Check it's correct, active, and not expired." }
        Fail "Could not reach the Licence Server at $LicenceServerUrl. Check this server's internet connection and try again."
    }
    $auth = @{ Authorization = "Bearer $token"; Accept = "application/vnd.oci.image.manifest.v1+json" }
    $manifest = Invoke-RestMethod -Uri "$Registry/v2/$Repository/manifests/$Version" -Headers $auth
    $layer = $manifest.layers | Where-Object { $_.annotations.'org.opencontainers.image.title' -eq $PackageName } | Select-Object -First 1
    if (-not $layer) { Fail "Version $Version was not found. Leave out -Version to install the latest." }
    $Version = $manifest.annotations.'org.opencontainers.image.version'
    Info "Downloading WITStream Connect $Version ($([Math]::Round($layer.size / 1MB)) MB)..."
    Invoke-WebRequest -Uri "$Registry/v2/$Repository/blobs/$($layer.digest)" -Headers @{ Authorization = "Bearer $token" } -OutFile $download
    $hash = (Get-FileHash $download -Algorithm SHA256).Hash.ToLower()
    if ("sha256:$hash" -ne $layer.digest) { Remove-Item $download -Force; Fail "The download was damaged (checksum mismatch). Run the command again." }
}

# 4. Stop the running service (an update), then put the new program in place.
#    "Apply now" ends the program and Windows starts it again 5 seconds
#    later, so a service that looks stopped can start again while the new
#    program is copied in, and the copy fails because the file is in use
#    (found 7 October 2026 by the release test, which updates straight
#    after Apply now). Each attempt stops the service, waits until no copy
#    of the program is running, then copies; it tries again for a minute.
New-Item -ItemType Directory -Force -Path $ProgramDir | Out-Null
$copied = $false
for ($attempt = 1; $attempt -le 12 -and -not $copied; $attempt++) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Stopped") {
        if ($attempt -eq 1) { Info "Stopping the running service..." }
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        try { $svc.WaitForStatus("Stopped", (New-TimeSpan -Seconds 60)) } catch { }
    }
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $ProgramExe }) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    try {
        # Copied, not moved: a moved file keeps the permissions of the folder it
        # was downloaded to (this account's own Temp), which Local Service cannot read.
        Copy-Item -Force $download $ProgramExe -ErrorAction Stop
        $copied = $true
    } catch {
        Start-Sleep -Seconds 5
    }
}
if (-not $copied) { Fail "The program could not be replaced because it is still running. Restart the server, then run the command again." }
Remove-Item -Force $download
Unblock-File $ProgramExe

# 5. Settings and data in ProgramData. A first install gets a starter
#    settings file with a generated API key; an update never touches it.
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
if (-not (Test-Path $ConfigFile)) {
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $apiKey = ([BitConverter]::ToString($bytes) -replace "-", "").ToLower()
    $config = [ordered]@{
        apiKey = $apiKey
        licence = [ordered]@{ licenceKey = $LicenceKey; licenceServerUrl = $LicenceServerUrl }
        connections = @()
    }
    # Written without a byte-order mark, which the service's JSON reader does not expect.
    [IO.File]::WriteAllText($ConfigFile, ($config | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Info "Created $ConfigFile with a generated dashboard API key (shown at the end)."
}
# The service runs as Local Service, which needs to write its settings, data and logs.
& icacls.exe $DataDir /grant "*S-1-5-19:(OI)(CI)M" /T /Q | Out-Null

# 6. The service: starts with Windows, runs as Local Service, and restarts
#    itself 5 seconds after stopping unexpectedly (which is also how
#    "Apply now" on the configuration screen applies saved settings).
if (-not $existing) {
    Info "Installing the service..."
    New-Service -Name $ServiceName -DisplayName $DisplayName -BinaryPathName "`"$ProgramExe`"" -StartupType Automatic -Description "WITStream Connect drilling data hub. Dashboard on port $(if ($Port) { $Port } else { 3000 })." | Out-Null
}
# Local Service rather than the all-powerful LocalSystem. (No password value:
# Windows PowerShell drops an empty one, and the account does not need it.)
& sc.exe config $ServiceName obj= "NT AUTHORITY\LocalService" | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Could not set the service to run as Local Service (sc.exe exit code $LASTEXITCODE)." }
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
# The program runs from its single file; versions before v0.2.54 unpacked
# themselves into a runtime folder here, no longer needed.
$environment = @()
if (Test-Path "$DataDir\runtime") { Remove-Item -Recurse -Force "$DataDir\runtime" -ErrorAction SilentlyContinue }
if ($Port) { $environment += "WITSTREAM_PORT=$Port" }
else {
    $previous = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name Environment -ErrorAction SilentlyContinue).Environment | Where-Object { $_ -like "WITSTREAM_PORT=*" }
    if ($previous) { $environment += $previous; $Port = [int]($previous -replace "WITSTREAM_PORT=", "") }
}
if (-not $Port) { $Port = 3000 }
if ($environment.Count -gt 0) {
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name Environment -Type MultiString -Value $environment
} else {
    Remove-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name Environment -ErrorAction SilentlyContinue
}

# 7. Windows Firewall: let other computers reach the dashboard and every
#    output port set on the configuration screen.
if (-not (Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $DisplayName -Direction Inbound -Program $ProgramExe -Action Allow -Profile Domain,Private | Out-Null
}

# 8. Start, then check the dashboard actually answers.
function ShowWhy {
    $log = Join-Path $DataDir "logs\service.log"
    if (Test-Path $log) { Info "Last lines of ${log}:"; Get-Content $log -Tail 25 | ForEach-Object { Info "  $_" } }
    Get-WinEvent -FilterHashtable @{ LogName = "Application"; Level = 2; StartTime = (Get-Date).AddMinutes(-10) } -MaxEvents 3 -ErrorAction SilentlyContinue |
        ForEach-Object { Info "Windows event: $($_.ProviderName): $($_.Message -split "`n" | Select-Object -First 6 | Out-String)" }
}

Info "Starting WITStream Connect on port $Port..."
try {
    Start-Service -Name $ServiceName
} catch {
    ShowWhy
    Fail "The service would not start: $($_.Exception.Message)"
}
$healthy = $false
for ($i = 0; $i -lt 90; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -lt 400) { $healthy = $true; break }
    } catch { }
    if ((Get-Service $ServiceName).Status -eq "Stopped" -and $i -gt 10) { break }
    Start-Sleep -Seconds 1
}

$apiKey = (Get-Content $ConfigFile -Raw | ConvertFrom-Json).apiKey
$address = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
if (-not $address) { $address = "<this server's address>" }

Info ""
if ($healthy) {
    Write-Host "$([char]0x2713) WITStream Connect$([char]0x00AE) is running." -ForegroundColor Green
    Info ""
    Info "1. Open a web browser on any computer that can reach this server and go to:"
    Info ""
    Write-Host "     http://${address}:$Port" -ForegroundColor White
    Info ""
    Info "2. The dashboard asks for your API key the first time you open it:"
    Info ""
    Write-Host "     API key: $apiKey" -ForegroundColor Green
    Info ""
    Info "   It is saved as apiKey in $ConfigFile."
    Info "   Windows Firewall now allows WITStream Connect on private and domain networks."
    Info ""
    Info "Settings, CSV/LAS output and certificates are kept in $DataDir; the log is in its logs folder."
    Info "To update later, run the same command again."
} else {
    ShowWhy
    Fail "The service did not answer on port $Port. See $DataDir\logs\service.log, or Windows Event Viewer, Windows Logs, Application, for the reason."
}
