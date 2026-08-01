# NASA APOD háttérkép beállítása PowerShellből

# API kulcs: prioritásban a környezeti változó
$apiKey = $env:NASA_API_KEY
if (-not $apiKey) { $apiKey = "DEMO_KEY" }
$apodUrl = "https://api.nasa.gov/planetary/apod?api_key=$apiKey"

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
                Write-Host "Próbálkozás $attempt sikertelen. Újrapróbálkozás $wait másodperc múlva..."
                Start-Sleep -Seconds $wait
            }
        }
    }
}

# APOD metaadatok lekérése (retry)
try {
    $apodData = Invoke-Retry -ScriptBlock { Invoke-RestMethod -Uri $apodUrl -ErrorAction Stop } -MaxRetries 3 -DelaySeconds 2
} catch {
    Write-Error "Nem sikerült lekérni az APOD metaadatokat: $_"
    exit 1
}

# Ellenőrizzük, hogy valóban kép-e (APOD néha videó)
if ($apodData.media_type -and $apodData.media_type -ne 'image') {
    Write-Host "A mai APOD nem kép (media_type = $($apodData.media_type)). Nem állítok be háttérképet."
    if ($apodData.url) { Write-Host "URL: $($apodData.url)" }
    exit 0
}

# Kép URL-je
$imageUrl = $apodData.hdurl
if (-not $imageUrl) { $imageUrl = $apodData.url }
if (-not $imageUrl) {
    Write-Error "Nincs elérhető kép URL az API válaszban."
    exit 1
}

# Letöltési hely: próbáljuk először a OneDrive Pictures mappát, ha nincs, fallback a helyi Pictures mappára
$oneDrivePics = Join-Path $env:USERPROFILE "OneDrive\Pictures"
$localPics = Join-Path $env:USERPROFILE "Pictures"
if (Test-Path $oneDrivePics) { $wallpaperDir = $oneDrivePics } elseif (Test-Path $localPics) { $wallpaperDir = $localPics } else { 
    # Ha egyik sem létezik, létrehozzuk a helyi Pictures mappát
    try {
        New-Item -Path $localPics -ItemType Directory -Force | Out-Null
        $wallpaperDir = $localPics
    } catch {
        Write-Error "Nem sikerült létrehozni a képmentési könyvtárat: $_"
        exit 1
    }
}

$wallpaperPath = Join-Path $wallpaperDir "apod_wallpaper.jpg"

# Kép letöltése (retry)
try {
    Invoke-Retry -ScriptBlock { Invoke-WebRequest -Uri $imageUrl -OutFile $wallpaperPath -ErrorAction Stop } -MaxRetries 4 -DelaySeconds 2
    Write-Host "Kép letöltve: $wallpaperPath"
} catch {
    Write-Error "Nem sikerült letölteni a képet: $_"
    exit 1
}

# Háttérkép beállítása Windows alatt
if (-not $IsWindows) {
    Write-Error "A háttérkép beállítása csak Windows rendszeren támogatott."
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
        Write-Host "Háttérkép sikeresen beállítva: $wallpaperPath"
        exit 0
    } else {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Error "A SystemParametersInfo hívás sikertelen. Win32 hiba: $err"
        exit 1
    }
} catch {
    Write-Error "Hiba történt a háttérkép beállítása közben: $_"
    exit 1
}
