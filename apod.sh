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

# --- Biztonságosabb letöltés: tmp fájl, retry, validálás (Content-Length vagy JPEG EOF) ---
TMP_IMG=$(mktemp "${PICTURES_DIR}/apod_XXXXXX") || TMP_IMG=$(mktemp -t apod)
cleanup_tmp() { rm -f "$TMP_IMG"; }
trap cleanup_tmp EXIT

# Erősebb curl beállítások: --fail (HTTP hibákra non-zero visszatérés), --retry, --continue-at - (folytatás),
# nagyobb --max-time, -L követés.
DOWNLOAD_CMD="curl -f -L --retry 5 --retry-delay 5 --max-time 120 --continue-at - -o '$TMP_IMG' '$IMAGE_URL'"

if ! invoke_retry "$DOWNLOAD_CMD" 4 2; then
    write_log "Nem sikerült letölteni a képet (curl visszatérés hibással)." 'ERROR'
else
    # Próbáljuk lekérni a Content-Length fejléct (ha van)
    CONTENT_LENGTH=$(curl -sI "$IMAGE_URL" | tr -d '\r' | awk -F': ' '/^[Cc]ontent-Length:/ {print $2; exit}')
    ACTUAL_SIZE=$(wc -c < "$TMP_IMG" | tr -d ' ')

    if [[ -n "$CONTENT_LENGTH" && "$ACTUAL_SIZE" -lt "$CONTENT_LENGTH" ]]; then
        write_log "A letöltött fájl kisebb mint a Content-Length ($ACTUAL_SIZE < $CONTENT_LENGTH). Újrapróbálkozás..." 'WARN'
        # Próbáljuk folytatni / újratölteni egyszer
        if ! curl -f -L --retry 3 --retry-delay 5 --max-time 120 --continue-at - -o "$TMP_IMG" "$IMAGE_URL"; then
            write_log "Újrapróbálkozás sikertelen." 'ERROR'
            rm -f "$TMP_IMG"
        fi
    else
        # Ha nincs Content-Length, vagy nem tudjuk összevetni, ellenőrizzük JPEG EOF (ffd9)
        if [[ -z "$CONTENT_LENGTH" ]]; then
            last_hex=$(tail -c 2 "$TMP_IMG" | xxd -p -l 2 2>/dev/null || printf "")
            if [[ -n "$last_hex" && "$last_hex" != "ffd9" ]]; then
                write_log "A fájl nem végződik JPEG EOF jellel (valószínűleg részleges). Újrapróbálkozás..." 'WARN'
                if ! curl -f -L --retry 3 --retry-delay 5 --max-time 120 --continue-at - -o "$TMP_IMG" "$IMAGE_URL"; then
                    write_log "Újrapróbálkozás sikertelen." 'ERROR'
                    rm -f "$TMP_IMG"
                fi
            fi
        fi
    fi

    # Ha minden OK (létezik és nem üres), mozgassuk át atomikusan a végső helyre
    if [[ -s "$TMP_IMG" ]]; then
        mv -f "$TMP_IMG" "$WALLPAPER_PATH"
        # cleanup_tmp trap törli már a TMP_IMG fájlt, de mv után már nincs mit törölni
        trap - EXIT
        write_log "Kép sikeresen letöltve és áthelyezve: $WALLPAPER_PATH" 'INFO'
    else
        write_log "A letöltött fájl üres vagy nem létezik a kísérlet után." 'ERROR'
    fi
fi
# --- vége változtatás ---

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

# AppleScript: háttérkép beállítása az összes monitoron (megbízhatóbb)
AS_CMD="tell application \"System Events\" to set picture of every desktop to (POSIX file \"$WALLPAPER_PATH_NORMALIZED\")"
write_log "AppleScript parancs futtatása: $AS_CMD" 'INFO'
AS_OUT=$(osascript -e "$AS_CMD" 2>&1)
AS_RC=$?
if [[ $AS_RC -eq 0 ]]; then
    write_log "Háttérkép sikeresen beállítva: $WALLPAPER_PATH_NORMALIZED" 'INFO'
    exit 0
else
    write_log "Hiba történt az AppleScript futtatása közben (rc=$AS_RC): $AS_OUT" 'ERROR'
    write_log "Próbáld meg kézzel futtatni az osascript parancsot a konzolból, és ellenőrizd az Automation engedélyeket." 'ERROR'
    exit 1
fi
