#!/bin/bash

# Funktion zum Erstellen eines Backups
create_backup() {
    local storage="/opt/pterodactyl/backups/panel"

    # Überprüfen, ob das Backup-Verzeichnis existiert
    if [ ! -d "$storage" ]; then
        mkdir -p "$storage"
        whiptail --title "Backup erforderlich" --msgbox "Damit du keine unschönen Erfahrungen machen musst, empfehlen wir dir ein Backup vom aktuellen Panel zu machen. Die Themes sind von anderen Entwicklern auf Github, die du auf unserer Website nachlesen kannst. Es ist nie ausgeschlossen, dass Fehler passieren. Man sagt ja immer: 'Kein Backup, kein Mitleid'.

Wir leiten dich nun weiter zu unserer Backup-Verwaltung. Erstelle dort bitte ein Backup für dein Panel. Wenn du das gemacht hast, kannst du zur Theme-Auswahl zurückkehren." 10 80

        # Skript ausführen
        curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/backup-verwaltung.sh | bash
    else
        manage_themes
    fi
}



# Funktion für die Theme-Verwaltung
manage_themes() {
    CHOICE=$(whiptail --title "Theme-Verwaltung" --menu "Wähle eine Option:" 15 60 4 \
    "1" "Farbauswahl" \
    "2" "Themes" \
    "3" "Backup wiederherstellen" 3>&1 1>&2 2>&3)

    case $CHOICE in
        1)
            color_selection
            ;;
        2)
            install_themes
            ;;
        3)
            restore_backup
            ;;
        *)
            echo "Ungültige Auswahl"
            ;;
    esac
}

# Funktion für die Farbauswahl
color_selection() {
    local color_choice=$(whiptail --title "Farbauswahl" --menu "Wähle eine Farbe aus:" 15 60 5 \
        "1" "Dunkelrot" \
        "2" "Dunkelblau" \
        "3" "Dunkelgelb" \
        "4" "Dunkelgrün" \
        "5" "Dunkellila" 3>&1 1>&2 2>&3)

    case $color_choice in
        1) apply_theme 1 ;;
        2) apply_theme 2 ;;
        3) apply_theme 3 ;;
        4) apply_theme 4 ;;
        5) apply_theme 5 ;;
        *) whiptail --title "Fehler" --msgbox "Ungültige Auswahl. Bitte wähle eine gültige Farboption." 8 45 ;;
    esac
}

# Funktion, um das Theme anzuwenden
apply_theme() {
    local selection=$1 # Die übergebene Nummer für das Farbthema
    {
        # Starte das externe Skript im Hintergrund und leite die Ausgabe um
        bash <(curl -s https://raw.githubusercontent.com/Sigma-Production/PteroFreeStuffinstaller/V1.10.1/resources/script.sh) <<< "1
$selection
n" &> /dev/null
    } &

    # Prozess-ID des Hintergrundprozesses
    PID=$!
    # Simulierter Fortschritt
    local progress=0
    while kill -0 $PID 2>/dev/null; do
        # Pausiert zufällig zwischen 0.2 und 4 Sekunden, damit wenigstens irgendwas passiert. Sonst wirkt das eingefroren.
        local sleep_time=$(echo "scale=1; $((RANDOM%8+2))/10" | bc)
        # Füge eine führende Null hinzu, wenn die Zahl kleiner als 1 ist
        sleep_time=$(echo $sleep_time | sed 's/^\./0./')
        sleep $sleep_time
        progress=$((progress >= 100 ? 100 : progress + 1)) # Erhöht den Fortschritt und prüft auf Maximum
        echo "XXX"
        echo "$progress"
        echo "XXX"
        [ $progress -eq 99 ] && echo "Es dauert länger als erwartet, es ist gleich fertig..." || echo "Bitte warten..."
    done | whiptail --title "Farbtheme wird angewendet" --gauge "Bitte warten..." 8 70 0

    # Wenn der Prozess vor 99% abgeschlossen ist, setze den Fortschritt auf 100%
    if [ $progress -ne 100 ]; then
        echo "XXX"
        echo "100"
        echo "XXX"
        echo "Das Farbthema wurde erfolgreich angewendet."
        sleep 1 | whiptail --title "Farbtheme wird angewendet" --gauge "Bitte warten..." 8 70 0
    fi

    # Warte auf den Abschluss des Hintergrundprozesses
    wait $PID
    EXIT_STATUS=$?

    # Überprüfe den Exit-Status
    if [ $EXIT_STATUS -eq 0 ]; then
        whiptail --title "Farbtheme Anwendung" --msgbox "Das Farbtheme wurde erfolgreich angewendet." 8 45
    else
        whiptail --title "Fehler" --msgbox "Es gab ein Problem bei der Anwendung des Farbthemes." 8 45
    fi

    # Kehre zum Hauptmenü zurück
    manage_themes
}



# Platzhalter für Themes-Installation
install_themes() {
    whiptail --msgbox "Platzhalter für Themes" 8 45
    manage_themes
}

# Funktion zum Wiederherstellen eines Backups
restore_backup() {
    local storage="/opt/pterodactyl/backups/panel"

    # Überprüfen, ob das Backup-Verzeichnis existiert
    if [ ! -d "$storage" ]; then
        whiptail --title "Problem" --msgbox "Es konnte kein Backup gefunden werden. Das Script kann somit den vorherigen Zustand nicht wiederherstellen." 10 60
        whiptail --title "Weiterleitung" --msgbox "Bitte drücke 'OK', um zur Neuinstallation des Panels zu gelangen." 10 60
        curl -sSL https://setup.germandactyl.de/ | sudo bash -s --
        return
    fi

    whiptail --title "Backup wiederherstellen" --msgbox "Um das Panel zu einem früheren Zustand wiederherzustellen, wirst du zur Backup-Verwaltung weitergeleitet. Wähle dort das Backup aus, das du wiederherstellen möchtest. Wenn du möchtest, kannst du danach ein anderes Theme ausprobieren." 10 80

    # Skript ausführen
    curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/backup-verwaltung.sh | bash
}






# Hauptfunktion des Skripts
main() {
    create_backup
    manage_themes
}

# Skript starten
main
