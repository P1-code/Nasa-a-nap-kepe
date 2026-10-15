# ==========================================
# NASA APOD háttérkép beállítása PowerShellből (Új API)
# ==========================================

$apodUrl = "https://science.nasa.gov/wp-json/wp/v2/apod-basic"

# Naplózás beállítása (opcionális fájlba)
$logDisabled = $false
if ($env:APOD_LOG_DISABLE -and $env:APOD_LOG_DISABLE -eq '1') { $logDisabled = $true }

# Konzol és kimeneti kódolás beállítása UTF-8-ra
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# Naplózási könyvtár: OneDrive Pictures -> Helyi Pictures
$oneDrivePics = Join-Path $env:USERPROFILE "OneDrive\Pictures"
$localPics = Join-Path $env:USERPROFILE "Pictures"

if (Test-Path $oneDrivePics) { 
    $logDir = $oneDrivePics 
} elseif (Test-Path $localPics) { 
    $logDir = $localPics 
} else {
    try { 
        New-Item -Path $localPics -ItemType Directory -Force | Out-Null
        $logDir = $localPics 
    } catch { 
        $logDir = $null 
    }
}

if (-not $logDisabled -and $logDir) { 
    $logPath = Join-Path $logDir "apod.log" 
} else { 
    $logPath = $null 
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $outLine = "[$ts] [$Level] $Message"

    switch ($Level) {
        'ERROR' { Write-Host $outLine -ForegroundColor Red }
        'WARN'  { Write-Host $outLine -ForegroundColor Yellow }
        default { Write-Host $outLine }
    }

    if (-not $logDisabled -and $logPath) {
        try {
            $encWithBOM = New-Object System.Text.UTF8Encoding $true
            $encNoBOM   = New-Object System.Text.UTF8Encoding $false
            if (-not (Test-Path $logPath)) {
                [System.IO.File]::WriteAllText($logPath, $outLine + [Environment]::NewLine, $encWithBOM)
            } else {
                [System.IO.File]::AppendAllText($logPath, $outLine + [Environment]::NewLine, $encNoBOM)
            }
        } catch {
            $warnTs = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Write-Host "[$warnTs] [WARN] Nem sikerült naplófájlba írni: $($_.Exception.Message)"
        }
    }
}

# Segédfüggvény: próbálkozás ismétléssel (retries + exponenciális backoff)
function Invoke-Retry {
    param(
        [ScriptBlock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 2
    )
    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        } catch {
            $attempt++
            if ($attempt -ge $MaxRetries) {
                throw $_
            } else {
                $wait = [int]($DelaySeconds * [math]::Pow(2, $attempt - 1))
                Write-Log "Próbálkozás $attempt sikertelen. Újrapróbálkozás $wait másodperc múlva..." 'WARN'
                Start-Sleep -Seconds $wait
            }
        }
    }
}

Write-Log "Lekérdezés indítása: $apodUrl" 'INFO'

# APOD metaadatok lekérése (retry)
try {
    $response = Invoke-Retry -ScriptBlock { Invoke-RestMethod -Uri $apodUrl -ErrorAction Stop } -MaxRetries 3 -DelaySeconds 2
    
    # Mivel a végpont tömböt ad vissza, CSAK a legelső elemet (a mai napot) választjuk ki
    if ($response -is [System.Array]) {
        $apodData = $response[0]
    } else {
        $apodData = $response
    }
    
    Write-Log "APOD metaadatok sikeresen lekérve." 'INFO'
} catch {
    Write-Log "Nem sikerült lekérni az APOD metaadatokat: $($_.Exception.Message)" 'ERROR'
    exit 1
}

# Ellenőrizzük, hogy valóban kép-e
if ($apodData.media_type -and $apodData.media_type -ne 'image') {
    Write-Log "A mai APOD nem kép (media_type = $($apodData.media_type)). Nem állítok be háttérképet." 'INFO'
    if ($apodData.url) { Write-Log "URL: $($apodData.url)" 'INFO' }
    exit 0
}

# Kép URL-je a kiválasztott egyetlen elembol
$imageUrl = $apodData.hdurl
if (-not $imageUrl) {
    $imageUrl = $apodData.url
}

# Biztonsági tisztítás: ha bármi miatt mégis több URL jönne át, az elsőt szedjük ki
if ($imageUrl -is [System.Array]) {
    $imageUrl = $imageUrl[0]
} elseif ($imageUrl -is [string] -and $imageUrl -match '\s') {
    $imageUrl = ($imageUrl -split '\s+')[0]
}

if (-not $imageUrl) {
    Write-Log "Nem található kép URL." 'ERROR'
    exit 1
}
Write-Log "Kép URL: $imageUrl" 'INFO'

# Letöltési hely meghatározása
if (Test-Path $oneDrivePics) { 
    $wallpaperDir = $oneDrivePics 
} elseif (Test-Path $localPics) { 
    $wallpaperDir = $localPics 
} else { 
    try {
        New-Item -Path $localPics -ItemType Directory -Force | Out-Null
        $wallpaperDir = $localPics
    } catch {
        Write-Log "Nem sikerült létrehozni a képmentési könyvtárat: $($_.Exception.Message)" 'ERROR'
        exit 1
    }
}

$wallpaperPath = Join-Path $wallpaperDir "apod_wallpaper.jpg"
Write-Log "Letöltési cél: $wallpaperPath" 'INFO'

# Kép letöltése (retry)
try {
    Invoke-Retry -ScriptBlock { Invoke-WebRequest -Uri $imageUrl -OutFile $wallpaperPath -ErrorAction Stop } -MaxRetries 4 -DelaySeconds 2
    Write-Log "Kép letöltve: $wallpaperPath" 'INFO'
} catch {
    Write-Log "Nem sikerült letölteni a képet: $($_.Exception.Message)" 'ERROR'
    exit 1
}

# Windows környezet ellenőrzése
$runningOnWindows = $false
try {
    if ($IsWindows -eq $true) { $runningOnWindows = $true }
} catch {}

if (-not $runningOnWindows) {
    if ($env:OS -eq 'Windows_NT') { 
        $runningOnWindows = $true 
    } else {
        try {
            if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
                $runningOnWindows = $true
            }
        } catch {}
    }
}

if (-not $runningOnWindows) {
    Write-Log "A háttérkép beállítása csak Windows rendszeren támogatott." 'ERROR'
    exit 1
}

# Interaktív munkamenet ellenőrzése
try {
    $isInteractive = [System.Environment]::UserInteractive
} catch {
    $isInteractive = $false
}
Write-Log "User: $env:USERNAME, Session: $env:SESSIONNAME, Interactive: $isInteractive" 'INFO'

if (-not $isInteractive) {
    Write-Log "Nem interaktív környezet — háttérkép beállítást kihagyom." 'WARN'
    exit 0
}

# Wallpaper típus betöltése C# P/Invoke segítségével
$wallpaperType = [AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object { $_.GetType("Wallpaper") } | Where-Object { $_ -ne $null } | Select-Object -First 1

if (-not $wallpaperType) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class Wallpaper {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
} else {
    Write-Log "Wallpaper típus már be van töltve — Add-Type kihagyva." 'INFO'
}

$SPI_SETDESKWALLPAPER = 20
$SPIF_UPDATEINIFILE = 1
$SPIF_SENDWININICHANGE = 2

try {
    $result = [Wallpaper]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $wallpaperPath, $SPIF_UPDATEINIFILE -bor $SPIF_SENDWININICHANGE)
    if ($result) {
        Write-Log "Háttérkép sikeresen beállítva: $wallpaperPath" 'INFO'
        exit 0
    } else {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log "A SystemParametersInfo hívás sikertelen. Win32 hiba: $err" 'ERROR'
        exit 1
    }
} catch {
    Write-Log "Hiba történt a háttérkép beállítása közben: $($_.Exception.Message)" 'ERROR'
    exit 1
}