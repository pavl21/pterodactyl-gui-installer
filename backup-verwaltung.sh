#!/bin/bash

# Hauptkonfigurationsdatei
settings_file="/opt/pterodactyl/.settings"

# Standardpfade für Backup-Quellen und -Ziele
default_backup_source_panel="/var/www/pterodactyl/"
default_backup_storage_panel="/opt/pterodactyl/backups/panel"
default_backup_source_server="/var/lib/pterodactyl/volumes/"
default_backup_storage_server="/opt/pterodactyl/backups/server"

# Haftungsausschluss
whiptail --msgbox "Dies ist die Backup-Verwaltung von GermanDactyl Setup. Dieses Script könnte noch an einigen Stellen fehlerhaft sein, zumindest läuft es unter einer normalen Pterodactyl Installation und einem Debian 11 System einwandfrei. Die Backups werden in '/opt/pterodactyl/' abgelegt, wobei man den Speicherpfad auch anpassen kann, zum Beispiel auf eine eingehängte HDD. Die Verwendung unterliegt deiner Verantwortung und GermanDactyl haftet nicht bei Datenverlust!" 14 70 --title "Backup-Verwaltung"



update_or_add_setting() {
    local file=$1
    local key=$2
    local value=$3

    if grep -q "^$key=" "$file"; then
        # Schlüssel existiert, also aktualisieren
        sed -i "/^$key=/c\\$key='$value'" "$file"
    else
        # Schlüssel existiert nicht, also hinzufügen
        echo "$key='$value'" >> "$file"
    fi
}



# Lade Einstellungen, falls vorhanden
if [ -f "$settings_file" ]; then
    while IFS='=' read -r key value; do
        case $key in
            backup_storage_panel) backup_storage_panel=$value ;;
            backup_storage_server) backup_storage_server=$value ;;
            max_backups_panel) max_backups_panel=$value ;;
            max_backups_server) max_backups_server=$value ;;
        esac
    done < "$settings_file"
else
    # Standardwerte, falls die Datei nicht existiert
    backup_storage_panel=$default_backup_storage_panel
    backup_storage_server=$default_backup_storage_server
    max_backups_panel=5
    max_backups_server=5
fi




# Stellt sicher, dass das Backup-Verzeichnis existiert
ensure_backup_storage_exists() {
    local storage=$1
    if [ ! -d "$storage" ]; then
        mkdir -p "$storage"
    fi
}

question_menu() {
    while true; do
        choice=$(whiptail --title "Backup-Verwaltung" --menu "Wähle die Backup-Art:" 15 40 3 \
        "1" "Panel-Backups" \
        "2" "Server-Backups" \
        "3" "Backup-Dienst beenden" 3>&1 1>&2 2>&3)

        case $choice in
            1) main_menu_panel;;
            2) main_menu_server;;
            3)
                # Hier wird der Befehl ausgeführt, wenn "Abbrechen" ausgewählt wird
                curl -sSL https://setup.germandactyl.de/ | sudo bash -s --
                exit 0;;
            *) break;;
        esac
    done
}


main_menu_panel() {
    while true; do
        choice=$(whiptail --title "Panel Backup-Menü" --menu "Wähle eine Option:" 15 60 6 \
        "1" "Backup erstellen" \
        "2" "Backup wiederherstellen" \
        "3" "Backup-Ort festlegen" \
        "4" "Backup-Zeitplan einrichten" \
        "5" "Backups löschen" \
        "6" "Backuplimit" 3>&1 1>&2 2>&3)

        case $choice in
            1) create_backup "$default_backup_source_panel" "$backup_storage_panel" "$max_backups_panel";;
            2) restore_backup_panel;;
            3) set_backup_location 'panel';;
            4) set_backup_schedule 'panel';;
            5) remove_backup 'panel';;
            6) limit_backup 'panel';;
            *) break;;
        esac
    done
}

main_menu_server() {
    while true; do
        choice=$(whiptail --title "Server Backup-Menü" --menu "Wähle eine Option:" 15 60 6 \
        "1" "Backup erstellen" \
        "2" "Backup wiederherstellen" \
        "3" "Backup-Ort festlegen" \
        "4" "Backup-Zeitplan einrichten" \
        "5" "Backups löschen" \
        "6" "Backuplimit" 3>&1 1>&2 2>&3)

        case $choice in
            1) create_backup "$default_backup_source_server" "$backup_storage_server" "$max_backups_server";;
            2) restore_backup_server;;
            3) set_backup_location 'server';;
            4) set_backup_schedule 'server';;
            5) remove_backup 'server';;
            6) limit_backup 'server';;
            *) break;;
        esac
    done
}

# Erstellen eines Backups
create_backup() {
    local source=$1
    local storage
    local max_backups=$3

    # Überprüfen, ob $default_backup_storage_server existiert und ihn gegebenenfalls erstellen
    if [ ! -d "$default_backup_storage_server" ]; then
        mkdir -p "$default_backup_storage_server"
    fi

    # Überprüfen, ob $default_backup_storage_panel existiert und ihn gegebenenfalls erstellen
    if [ ! -d "$default_backup_storage_panel" ]; then
        mkdir -p "$default_backup_storage_panel"
    fi

    # Überprüfen, ob es sich um ein Panel- oder Server-Backup handelt
    if [ "$source" == "/var/www/pterodactyl/" ]; then
        storage=$default_backup_storage_panel
    elif [ "$source" == "/var/lib/pterodactyl/volumes/" ]; then
        storage=$default_backup_storage_server
    else
        whiptail --title "Fehler" --msgbox "Ungültiger Quellpfad." 8 78
        return
    fi

    current_time=$(date +"%d.%m.%Y-%H:%M")
    backup_file_name="Backup_${current_time}_Uhr.tar.gz"
    total_size=$(du -sb "$source" | awk '{print $1}')

    (tar -cf - "$source" | pv -n -s "$total_size" | gzip > "$storage/$backup_file_name") 2>&1 | whiptail --title "Backup erstellen" --gauge "Das Backup wird angelegt..." 6 50 0
    if [ $? -eq 0 ]; then
        whiptail --title "Erfolg" --msgbox "Backup erfolgreich erstellt: $backup_file_name" 8 78
        manage_backup_rotation "$storage" "$max_backups"
    else
        whiptail --title "Fehler" --msgbox "Es ist ein Fehler beim erstellen des Backups aufgetreten. Ist genug Speicher frei? Ist der Pfad auch wirklich vorhanden? Hast du genügend Berechtigungen?." 8 78
    fi
}



# Backup wiederherstellen
restore_backup_panel() {
    local storage=$backup_storage_panel
    restore_backup "$storage" "Panel-Backup"
}

restore_backup_server() {
    local storage=$backup_storage_server
    restore_backup "$storage" "Server-Backup"
}

restore_backup() {
    local storage=$1
    ensure_backup_storage_exists $storage

    # Erstelle eine Liste von Backup-Dateien aus dem spezifizierten Verzeichnis
    backups=($(ls $storage | grep 'Backup_.*_Uhr.tar.gz'))

    if [ ${#backups[@]} -eq 0 ]; then
        whiptail --title "Fehler" --msgbox "Keine Backups gefunden im Verzeichnis: $storage" 8 78
        return
    fi

    # Erstelle ein Array mit den Optionen für das Whiptail-Menü
    local menu_options=()
    for i in "${!backups[@]}"; do
        menu_options+=($((i+1)) "${backups[$i]}")
    done

    # Zeige das Whiptail-Menü mit den gefundenen Backup-Dateien
    restore_file=$(whiptail --title "Backup wiederherstellen" --menu "Wähle ein Backup aus:" 20 78 10 "${menu_options[@]}" 3>&1 1>&2 2>&3)

    if [ $? -eq 0 ]; then
        # Der Benutzer hat ein Backup ausgewählt; extrahiere den Dateinamen
        selected_backup="${backups[$((restore_file-1))]}"
        backup_file="$storage/$selected_backup"
        total_size=$(du -sb $backup_file | awk '{print $1}')

        # Verwende pv und tar, um das Backup wiederherzustellen
        (pv -n -s "$total_size" "$backup_file" | tar -xzf - -C /) 2>&1 | whiptail --title "Backup wiederherstellen" --gauge "Backup wird wiederhergestellt..." 6 50 0
        if [ $? -eq 0 ]; then
            whiptail --title "Erfolg" --msgbox "Backup erfolgreich wiederhergestellt: $selected_backup" 8 78
        else
            whiptail --title "Fehler" --msgbox "Fehler bei der Wiederherstellung des Backups." 8 78
        fi
    else
        whiptail --title "Abgebrochen" --msgbox "Wiederherstellung abgebrochen." 8 78
    fi
}

# Backups löschen
remove_backup() {
    local type=$1
    local storage=$([ "$type" == "panel" ] && echo "$backup_storage_panel" || echo "$backup_storage_server")

    if whiptail --title "Warnung" --yesno "Alle Backups im Verzeichnis $storage werden gelöscht. Fortfahren?" 10 60; then
        find "$storage" -type f -name '*.tar.gz' -print0 | pv -n0 | xargs -0 rm
        if [ $? -eq 0 ]; then
            whiptail --title "Erfolg" --msgbox "Alle Backups wurden erfolgreich gelöscht." 8 78
        else
            whiptail --title "Fehler" --msgbox "Es gab einen Fehler beim Löschen der Backups. Möglicherweise existiert der Pfad bereits nicht mehr?" 8 78
        fi
    else
        whiptail --title "Abgebrochen" --msgbox "Löschvorgang abgebrochen." 8 78
    fi

    question_menu
}

# Limits für Anzahl an Backups
limit_backup() {
    local type=$1
    local current_limit=$([ "$type" == "panel" ] && echo "$max_backups_panel" || echo "$max_backups_server")
    local new_limit=$(whiptail --title "Backuplimit festlegen" --inputbox "Gib die maximale Anzahl der zu behaltenden Backups für $type ein:" 10 60 "$current_limit" 3>&1 1>&2 2>&3)

    if [ -n "$new_limit" ] && [ "$new_limit" -eq "$new_limit" ] 2>/dev/null; then
        if [ "$type" == "panel" ]; then
            max_backups_panel=$new_limit
            update_or_add_setting "$settings_file" "max_backups_panel" "$max_backups_panel"
        else
            max_backups_server=$new_limit
            update_or_add_setting "$settings_file" "max_backups_server" "$max_backups_server"
        fi
        whiptail --title "Erfolg" --msgbox "Das Backuplimit für $type wurde auf $new_limit gesetzt." 8 78
    else
        whiptail --title "Fehler" --msgbox "Ungültige Eingabe. Bitte gib eine gültige Zahl ein." 8 78
    fi
}



# Standort des Backups wählen - Optional
set_backup_location() {
    # Funktion läuft nicht einwandfrei
    whiptail --msgbox "Dieser Teil ist noch sehr anfällig auf Fehler und sollte nicht verändert werden. Dadurch wird zwar das Erstellen des Backups nicht verhindert, aber das Script weiß dann nicht mehr, wo sie abgelegt werden." 14 70 --title "WARNUNG"
    local type=$1
    local current_storage
    if [ "$type" == "panel" ]; then
        current_storage=$backup_storage_panel
    else
        current_storage=$backup_storage_server
    fi

    new_location=$(whiptail --title "Backup-Ort festlegen" --inputbox "Gib den neuen Pfad für die Backups ein:" 10 60 "$current_storage" 3>&1 1>&2 2>&3)

    # Überprüfen, ob die Eingabe nicht leer ist und sich vom aktuellen Pfad unterscheidet
    if [ -n "$new_location" ] && [ "$new_location" != "$current_storage" ]; then
        if [ "$type" == "panel" ]; then
            backup_storage_panel=$new_location
            update_or_add_setting "$settings_file" "backup_storage_panel" "$backup_storage_panel"
        else
            backup_storage_server=$new_location
            update_or_add_setting "$settings_file" "backup_storage_server" "$backup_storage_server"
        fi
        whiptail --title "Erfolg" --msgbox "Backup-Ort wurde festgelegt auf: $new_location" 8 78
    elif [ -z "$new_location" ]; then
        whiptail --title "Fehler" --msgbox "Kein Pfad angegeben oder Pfad entspricht dem aktuellen. Bitte gib einen gültigen Pfad ein." 8 78
    fi
}



manage_backup_rotation() {
    local storage=$1
    local max_backups=$2

    # Erstelle eine Liste der Backups, sortiert nach Erstellungsdatum (älteste zuerst)
    backup_files=($(ls -t $storage/Backup_*.tar.gz))

    # Überprüfe, ob $max_backups ein gültiger numerischer Wert ist
    if [[ ! "$max_backups" =~ ^[0-9]+$ ]]; then
        echo "Ungültiger Wert für max_backups: $max_backups"
        return 1
    fi

    # Überprüfe, ob die Anzahl der Backups größer als das Maximum ist
    while [ ${#backup_files[@]} -gt $max_backups ]; do
        oldest_backup=${backup_files[-1]}
        rm -f "$oldest_backup"
        backup_files=("${backup_files[@]:0:${#backup_files[@]}-1}")
    done
}


set_backup_schedule() {
    local type=$1
    local cron_job

    schedule=$(whiptail --title "Backup-Zeitplan einrichten" --menu "Jede Auswahl findet um 4 Uhr nachts statt. Bitte wähle eine aus:" 20 78 7 \
    "1" "Täglich" \
    "2" "Monatlich am ersten Tag des Monats" \
    "3" "Jeden Sonntag" \
    "4" "Jeden Montag" \
    "5" "Jeden Dienstag" \
    "6" "Jeden Mittwoch" \
    "7" "Jeden Donnerstag" \
    "8" "Jeden Freitag" \
    "9" "Jeden Samstag" \
    "10" "Ausschalten" 3>&1 1>&2 2>&3)

    case $schedule in
        1) cron_job="0 4 * * *";;
        2) cron_job="0 4 1 * *";;
        3) cron_job="0 4 * * 0";;
        4) cron_job="0 4 * * 1";;
        5) cron_job="0 4 * * 2";;
        6) cron_job="0 4 * * 3";;
        7) cron_job="0 4 * * 4";;
        8) cron_job="0 4 * * 5";;
        9) cron_job="0 4 * * 6";;
        10) # Deaktiviere den Backup-Zeitplan
            (crontab -l 2>/dev/null | grep -v "/opt/pterodactyl/backup-plan.sh") | crontab -
            whiptail --title "Erfolg" --msgbox "Backup-Zeitplan wurde deaktiviert." 8 78
            return 0;;
        *) return 1;;
    esac

    # Ersetze vorhandene crontab-Einträge
    (crontab -l 2>/dev/null | grep -v "/opt/pterodactyl/backup-plan.sh"; echo "$cron_job /opt/pterodactyl/backup-plan.sh") | crontab -

    whiptail --title "Erfolg" --msgbox "Backup-Zeitplan erfolgreich angepasst." 8 78
}



question_menu


