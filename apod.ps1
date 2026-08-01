# NASA APOD háttérkép beállítása PowerShellből

# UTF-8 kimenet beállítása, hogy a terminálban jól jelenjenek meg a nemzeti karakterek 
[Native.Kernel32]::SetConsoleOutputCP(65001) | Out-Null
[Native.Kernel32]::SetConsoleCP(65001) | Out-Null

# API kulcs: prioritásban a környezeti változó
$apiKey = $env:NASA_API_KEY
if (-not $apiKey) { $apiKey = "DEMO_KEY" }
$apodUrl = "https://api.nasa.gov/planetary/apod?api_key=$apiKey"

# Naplózás beállítása (opcionális fájlba)
# Állítsd APOD_LOG_DISABLE=1 környezeti változót, ha nem szeretnéd a fájlba írást.
$logDisabled = $false
if ($env:APOD_LOG_DISABLE -and $env:APOD_LOG_DISABLE -eq '1') { $logDisabled = $true }

# Naplózási könyvtár: preferáljuk a OneDrive Pictures-t, majd a helyi Pictures-t
$oneDrivePics = Join-Path $env:USERPROFILE "OneDrive\Pictures"
$localPics = Join-Path $env:USERPROFILE "Pictures"
if (Test-Path $oneDrivePics) { $logDir = $oneDrivePics } elseif (Test-Path $localPics) { $logDir = $localPics } else {
    try { New-Item -Path $localPics -ItemType Directory -Force | Out-Null; $logDir = $localPics } catch { $logDir = $null }
}

if (-not $logDisabled -and $logDir) { $logPath = Join-Path $logDir "apod.log" } else { $logPath = $null }

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    if ($Level -eq 'ERROR') { Write-Error $line } else { Write-Host $line }

    if (-not $logDisabled -and $logPath) {
        try {
            Add-Content -Path $logPath -Value $line -ErrorAction Stop
        } catch {
            # Nem akadályozzuk a futást, csak írjuk ki konzolra, ha a fájlírás sikertelen
            Write-Host "[$ts] [WARN] Nem sikerült naplófájlba írni: $($_.Exception.Message)"
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
    $apodData = Invoke-Retry -ScriptBlock { Invoke-RestMethod -Uri $apodUrl -ErrorAction Stop } -MaxRetries 3 -DelaySeconds 2
    Write-Log "APOD metaadatok sikeresen lekérve." 'INFO'
} catch {
    Write-Log "Nem sikerült lekérni az APOD metaadatokat: $($_.Exception.Message)" 'ERROR'
    exit 1
}

# Ellenőrizzük, hogy valóban kép-e (APOD néha videó)
if ($apodData.media_type -and $apodData.media_type -ne 'image') {
    Write-Log "A mai APOD nem kép (media_type = $($apodData.media_type)). Nem állítok be háttérképet." 'INFO'
    if ($apodData.url) { Write-Log "URL: $($apodData.url)" 'INFO' }
    exit 0
}

# Kép URL-je
$imageUrl = $apodData.hdurl
if (-not $imageUrl) { $imageUrl = $apodData.url }
if (-not $imageUrl) {
    Write-Log "Nincs elérhető kép URL az API válaszban." 'ERROR'
    exit 1
}
Write-Log "Kép URL: $imageUrl" 'INFO'

# Letöltési hely: próbáljuk először a OneDrive Pictures mappát, ha nincs, fallback a helyi Pictures mappára
if (Test-Path $oneDrivePics) { $wallpaperDir = $oneDrivePics } elseif (Test-Path $localPics) { $wallpaperDir = $localPics } else { 
    # Ha egyik sem létezik, létrehozzuk a helyi Pictures mappát
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

# Háttérkép beállítása Windows alatt — megbízható OS ellenőrzés (támogatja a Windows PowerShell 5.1-et és PowerShell Core-t)
$runningOnWindows = $false
try {
    if ($IsWindows -eq $true) { $runningOnWindows = $true }
} catch {
    # $IsWindows lehet, hogy nincs definiálva (pl. Windows PowerShell 5.1), ezért a fallback-et használjuk
}

if (-not $runningOnWindows) {
    if ($env:OS -eq 'Windows_NT') { $runningOnWindows = $true }
    else {
        try {
            if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
                $runningOnWindows = $true
            }
        } catch {
            # Ha ez sem működik, marad false
        }
    }
}

if (-not $runningOnWindows) {
    Write-Log "A háttérkép beállítása csak Windows rendszeren támogatott." 'ERROR'
    exit 1
}

Add-Type @"
using System.Runtime.InteropServices;
public class Wallpaper {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@

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
