#!/bin/bash

# Lade Whiptail-Farben
source "$(dirname "$0")/whiptail-colors.sh" 2>/dev/null || source /opt/pterodactyl/whiptail-colors.sh 2>/dev/null || true

# Lade install-scripts.sh für call_script() Funktion
source "$(dirname "$0")/install-scripts.sh" 2>/dev/null || source /opt/pterodactyl/install-scripts.sh 2>/dev/null || true

# Log-Datei für Theme-Installation
THEME_LOG="/opt/pterodactyl/theme-installation.log"

# Logging-Funktion
log_theme() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$THEME_LOG"
}

# Funktion zum Erstellen eines Backups
create_backup() {
    local storage="/opt/pterodactyl/backups/panel"

    log_theme "Theme-Verwaltung gestartet"

    # Überprüfen, ob das Backup-Verzeichnis existiert
    if [ ! -d "$storage" ]; then
        mkdir -p "$storage"
        log_theme "Backup-Verzeichnis nicht gefunden, leite zur Backup-Erstellung weiter"

        whiptail_warning --title "Backup erforderlich" --msgbox "Damit du keine unschönen Erfahrungen machen musst, empfehlen wir dir ein Backup vom aktuellen Panel zu machen. Die Themes sind von anderen Entwicklern auf Github, die du auf unserer Website nachlesen kannst. Es ist nie ausgeschlossen, dass Fehler passieren. Man sagt ja immer: 'Kein Backup, kein Mitleid'.

Wir leiten dich nun weiter zu unserer Backup-Verwaltung. Erstelle dort bitte ein Backup für dein Panel. Wenn du das gemacht hast, kannst du zur Theme-Auswahl zurückkehren." 20 80

        # Backup-Verwaltung aufrufen (nutzt lokale Kopie)
        call_script "backup-verwaltung.sh"
    else
        log_theme "Backup-Verzeichnis existiert, fahre mit Theme-Verwaltung fort"
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
            echo "Führe den Befehl 'curl -sSL https://setup.germandactyl.de/ | sudo bash -s --' aus"
            curl -sSL https://setup.germandactyl.de/ | sudo bash -s --
            ;;
    esac
}


# Funktion für die Farbauswahl
color_selection() {
    local color_choice=$(whiptail --title "Farbauswahl" --menu "Wähle eine Farbe aus, alle Themes sind von Sigma-Production." 15 60 5 \
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
        *) whiptail_error --title "Fehler" --msgbox "Ungültige Auswahl. Bitte wähle eine gültige Farboption." 8 45 ;;
    esac
}

# Rollback-Funktion bei Theme-Fehlern
rollback_theme() {
    local storage="/opt/pterodactyl/backups/panel"

    log_theme "FEHLER: Theme-Installation fehlgeschlagen, versuche Rollback"

    if [ ! -d "$storage" ]; then
        whiptail_error --title "Rollback nicht möglich" --msgbox "FEHLER: Kein Backup gefunden!\n\nEin Rollback ist nicht möglich.\n\nBitte stelle das Panel manuell wieder her oder führe eine Neuinstallation durch." 12 65
        log_theme "FEHLER: Rollback fehlgeschlagen - kein Backup vorhanden"
        return 1
    fi

    if whiptail --title "Theme-Rollback" --yesno "Möchtest du das letzte Backup wiederherstellen?\n\nDies wird das Theme-Update rückgängig machen." 10 65; then
        log_theme "Benutzer hat Rollback bestätigt, starte Wiederherstellung"
        call_script "backup-verwaltung.sh"
        log_theme "Rollback-Prozess abgeschlossen"
    else
        log_theme "Benutzer hat Rollback abgebrochen"
    fi
}

# Funktion, um das Theme anzuwenden
apply_theme() {
    local selection=$1 # Die übergebene Nummer für das Farbthema
    local theme_names=("Dunkelrot" "Dunkelblau" "Dunkelgelb" "Dunkelgrün" "Dunkellila")
    local theme_name="${theme_names[$((selection-1))]}"

    log_theme "Theme-Installation gestartet: $theme_name (Auswahl: $selection)"

    # Erstelle temporäres Backup-Marker
    local backup_marker="/tmp/theme_backup_$(date +%s).marker"
    touch "$backup_marker"

    {
        # Starte das externe Skript im Hintergrund und leite die Ausgabe um
        bash <(curl -s https://raw.githubusercontent.com/Sigma-Production/PteroFreeStuffinstaller/V1.10.1/resources/script.sh) <<< "1
$selection
n" &> /tmp/theme_install.log
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

    # Cleanup
    rm -f "$backup_marker"

    # Überprüfe den Exit-Status
    if [ $EXIT_STATUS -eq 0 ]; then
        log_theme "Theme-Installation erfolgreich: $theme_name"
        whiptail_success --title "Farbtheme Anwendung" --msgbox "Das Farbtheme wurde erfolgreich angewendet.\n\nTheme: $theme_name" 10 50
    else
        log_theme "FEHLER: Theme-Installation fehlgeschlagen: $theme_name (Exit-Code: $EXIT_STATUS)"

        # Zeige Fehlerdetails aus Log
        if [ -f /tmp/theme_install.log ]; then
            log_theme "Theme-Fehlerlog: $(tail -n 5 /tmp/theme_install.log)"
        fi

        if whiptail_error --title "Theme-Installation fehlgeschlagen" --yesno "FEHLER: Bei der Theme-Installation ist ein Fehler aufgetreten.\n\nTheme: $theme_name\n\nMöchtest du einen Rollback durchführen?" 12 65; then
            rollback_theme
        else
            log_theme "Benutzer hat Rollback nach Fehler abgelehnt"
        fi
    fi

    # Kehre zum Hauptmenü zurück
    manage_themes
}



# Platzhalter für Themes-Installation
install_themes() {
    whiptail_info --msgbox "Platzhalter für Themes" 8 45
    manage_themes
}

# Funktion zum Wiederherstellen eines Backups
restore_backup() {
    local storage="/opt/pterodactyl/backups/panel"

    # Überprüfen, ob das Backup-Verzeichnis existiert
    if [ ! -d "$storage" ]; then
        whiptail_error --title "Problem" --msgbox "Es konnte kein Backup gefunden werden. Das Script kann somit den vorherigen Zustand nicht wiederherstellen." 10 60
        whiptail_info --title "Weiterleitung" --msgbox "Bitte drücke 'OK', um zur Neuinstallation des Panels zu gelangen." 10 60
        curl -sSL https://setup.germandactyl.de/ | sudo bash -s --
        return
    fi

    whiptail_info --title "Backup wiederherstellen" --msgbox "Um das Panel zu einem früheren Zustand wiederherzustellen, wirst du zur Backup-Verwaltung weitergeleitet. Wähle dort das Backup aus, das du wiederherstellen möchtest. Wenn du möchtest, kannst du danach ein anderes Theme ausprobieren." 10 80

    # Backup-Verwaltung aufrufen (nutzt lokale Kopie)
    call_script "backup-verwaltung.sh"
}

# Hauptfunktion des Skripts
main() {
    create_backup
    manage_themes
}

# Skript starten
main
