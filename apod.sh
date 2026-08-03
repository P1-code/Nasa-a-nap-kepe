#!/bin/bash

# NASA APOD háttérkép beállítása macOS-en

# API kulcs: prioritásban a környezeti változó
API_KEY="${NASA_API_KEY:-DEMO_KEY}"
APOD_URL="https://api.nasa.gov/planetary/apod?api_key=$API_KEY"

# Naplózás beállítása (opcionális fájlba)
# Állítsd APOD_LOG_DISABLE=1 környezeti változót, ha nem szeretnéd a fájlba írást.
LOG_DISABLED=false
if [[ "${APOD_LOG_DISABLE:-0}" == "1" ]]; then
    LOG_DISABLED=true
fi

# Naplózási könyvtár: Pictures mappa
PICTURES_DIR="$HOME/Pictures"
if [[ ! -d "$PICTURES_DIR" ]]; then
    mkdir -p "$PICTURES_DIR" 2>/dev/null || PICTURES_DIR=null
fi

if [[ "$LOG_DISABLED" == "false" && "$PICTURES_DIR" != "null" ]]; then
    LOG_PATH="$PICTURES_DIR/apod.log"
else
    LOG_PATH=""
fi

# Naplózási függvény
write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local output="[$timestamp] [$level] $message"

    # Konzolra írás színnel
    case "$level" in
        ERROR)
            echo -e "\033[0;31m$output\033[0m" >&2
            ;;
        WARN)
            echo -e "\033[0;33m$output\033[0m"
            ;;
        *)
            echo "$output"
            ;;
    esac

    # Fájlba írás
    if [[ "$LOG_DISABLED" == "false" && -n "$LOG_PATH" ]]; then
        echo "$output" >> "$LOG_PATH" 2>/dev/null || true
    fi
}

# Segédfüggvény: próbálkozás ismétléssel (retries + exponenciális backoff)
invoke_retry() {
    local command="$1"
    local max_retries="${2:-3}"
    local delay_seconds="${3:-2}"
    local attempt=0

    while true; do
        if eval "$command"; then
            return 0
        else
            ((attempt++))
            if [[ $attempt -ge $max_retries ]]; then
                return 1
            else
                local wait=$((delay_seconds * (2 ** (attempt - 1))))
                write_log "Próbálkozás $attempt sikertelen. Újrapróbálkozás $wait másodperc múlva..." 'WARN'
                sleep "$wait"
            fi
        fi
    done
}

write_log "Lekérdezés indítása: $APOD_URL" 'INFO'

# APOD metaadatok lekérése (retry)
APOD_JSON=$(mktemp)
if ! invoke_retry "curl -s --max-time 10 -o '$APOD_JSON' '$APOD_URL' && [[ -s '$APOD_JSON' ]]" 3 2; then
    write_log "Nem sikerült lekérni az APOD metaadatokat." 'ERROR'
    rm -f "$APOD_JSON"
    exit 1
fi

# JSON feldolgozása (jq vagy alapvető shell)
if command -v jq &>/dev/null; then
    MEDIA_TYPE=$(jq -r '.media_type // empty' "$APOD_JSON")
    IMAGE_URL=$(jq -r '.hdurl // .url // empty' "$APOD_JSON")
    TITLE=$(jq -r '.title // empty' "$APOD_JSON")
else
    # Fallback: alapvető regex alapú feldolgozás
    MEDIA_TYPE=$(grep -o '"media_type":"[^"]*"' "$APOD_JSON" | head -1 | cut -d'"' -f4)
    IMAGE_URL=$(grep -o '"hdurl":"[^"]*"' "$APOD_JSON" | head -1 | cut -d'"' -f4)
    if [[ -z "$IMAGE_URL" ]]; then
        IMAGE_URL=$(grep -o '"url":"[^"]*"' "$APOD_JSON" | head -1 | cut -d'"' -f4)
    fi
    TITLE=$(grep -o '"title":"[^"]*"' "$APOD_JSON" | head -1 | cut -d'"' -f4)
fi

rm -f "$APOD_JSON"

write_log "APOD metaadatok sikeresen lekérve." 'INFO'

# Ellenőrizzük, hogy valóban kép-e (APOD néha videó)
if [[ -n "$MEDIA_TYPE" && "$MEDIA_TYPE" != "image" ]]; then
    write_log "A mai APOD nem kép (media_type = $MEDIA_TYPE). Nem állítok be háttérképet." 'INFO'
    if [[ -n "$IMAGE_URL" ]]; then
        write_log "URL: $IMAGE_URL" 'INFO'
    fi
    exit 0
fi

# Kép URL-je
if [[ -z "$IMAGE_URL" ]]; then
    write_log "Nincs elérhető kép URL az API válaszban." 'ERROR'
    exit 1
fi

write_log "Kép URL: $IMAGE_URL" 'INFO'
write_log "Cím: $TITLE" 'INFO'

# Letöltési cél
WALLPAPER_PATH="$PICTURES_DIR/apod_wallpaper.jpg"
write_log "Letöltési cél: $WALLPAPER_PATH" 'INFO'

# Kép letöltése (retry)
if ! invoke_retry "curl -s --max-time 30 -L -o '$WALLPAPER_PATH' '$IMAGE_URL' && [[ -s '$WALLPAPER_PATH' ]]" 4 2; then
    write_log "Nem sikerült letölteni a képet." 'ERROR'
    # Nem lépünk ki, megpróbáljuk az előző képet beállítani ha létezik
fi

# Ellenőrzés: létezik-e a kép
if [[ ! -f "$WALLPAPER_PATH" ]]; then
    write_log "A háttérkép fájl nem létezik: $WALLPAPER_PATH" 'ERROR'
    exit 1
fi

# Háttérkép beállítása macOS-en
# Az AppleScript korlátja: az elérési út maximum ~1000 karakter lehet
# Ha szükséges, normalizáljuk az elérési utat
WALLPAPER_PATH_NORMALIZED=$(cd "$(dirname "$WALLPAPER_PATH")" && pwd)/$(basename "$WALLPAPER_PATH")

write_log "Háttérkép beállítása macOS-en: $WALLPAPER_PATH_NORMALIZED" 'INFO'

# AppleScript: háttérkép beállítása az összes monitoron
if osascript -e "tell application \"Finder\" to set desktop picture to POSIX file \"$WALLPAPER_PATH_NORMALIZED\"" 2>/dev/null; then
    write_log "Háttérkép sikeresen beállítva: $WALLPAPER_PATH_NORMALIZED" 'INFO'
    exit 0
else
    write_log "Hiba történt a háttérkép beállítása közben (AppleScript)." 'ERROR'
    exit 1
fi
