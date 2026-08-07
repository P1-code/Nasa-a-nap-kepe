# Nasa-a-nap-kepe
Ez a PowerShell-parancsfájl lekérdezi a NASA „A nap csillagászati képe” (APOD) című sorozatát,
letölti a képet, majd azt beállítja a Windows asztali háttérképeként.

Windows verzió -» apod.sh1

macOS verzió -» apod.sh

macOS-en a script időzített futtatásához, a launchagents-ben található minta plist fájlt írd át a te felhasználódra, időpontodra, majd másold be a ~/Library/LaunchAgents
mappába. Ha nincs még ilyen mappa, hozd létre. Ezután a 

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.apod.plist

paranccsal add hozzá a feladatlistához
