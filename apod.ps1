# NASA APOD háttérkép beállítása PowerShellből

$apiKey = "DEMO_KEY"
$apodUrl = "https://api.nasa.gov/planetary/apod?api_key=$apiKey"

# APOD metaadatok lekérése
$apodData = Invoke-RestMethod -Uri $apodUrl

# Kép URL-je
$imageUrl = $apodData.hdurl
if (-not $imageUrl) { $imageUrl = $apodData.url }

# Letöltési hely
$wallpaperPath = "$env:USERPROFILE\OneDrive\Pictures\apod_wallpaper.jpg"

# Kép letöltése
Invoke-WebRequest -Uri $imageUrl -OutFile $wallpaperPath

# Háttérkép beállítása
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

[Wallpaper]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $wallpaperPath, $SPIF_UPDATEINIFILE -bor $SPIF_SENDWININICHANGE)
