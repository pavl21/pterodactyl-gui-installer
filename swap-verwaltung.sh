#!/bin/bash

# Funktion zur Überprüfung, ob Swap bereits vorhanden ist
check_swap() {
    if [[ -e /swapfile ]]; then
        whiptail --title "Swap-Speicher existiert bereits" --yesno "Swap-Speicher ist bereits vorhanden. Möchtest du den vorhandenen Swap-Speicher entfernen oder anpassen?" 10 60
        response=$?
        if [ $response -eq 0 ]; then
            # Deaktiviere Swap mit Error-Handling
            if ! sudo swapoff /swapfile 2>/dev/null; then
                whiptail --title "Warnung" --msgbox "WARNUNG: Swap konnte nicht deaktiviert werden.\n\nMöglicherweise ist er bereits inaktiv oder wird verwendet." 10 65
            fi

            # Entferne Swap-Datei mit Error-Handling
            if ! sudo rm /swapfile 2>/dev/null; then
                whiptail --title "Fehler" --msgbox "FEHLER: Swap-Datei konnte nicht gelöscht werden.\n\nBitte prüfe die Berechtigungen." 10 60
                menu
                return
            fi

            whiptail --title "Swap-Speicher entfernt" --msgbox "Der vorhandene Swap-Speicher wurde erfolgreich entfernt." 10 60
            create_swap
        else
            menu
        fi
    else
        create_swap
    fi
}

# GermanDactyl Menü
menu() {
    curl -sSL https://setup.germandactyl.de/ | sudo bash -s --
}

# Funktion zum Erstellen von Swap
create_swap() {
    size=$(whiptail --title "Swap-Speicher erstellen" --inputbox "Gebe die gewünschte Swap-Größe in MB ein:" 10 60 3>&1 1>&2 2>&3)
    response=$?
    if [ $response -eq 0 ]; then
        if [[ $size =~ ^[0-9]+$ ]]; then
            # Prüfe ob genug Speicherplatz verfügbar ist
            available_space=$(df / | awk 'NR==2 {print $4}')
            available_space_mb=$((available_space / 1024))

            if [ $size -gt $available_space_mb ]; then
                whiptail --title "Nicht genug Speicherplatz" --msgbox "FEHLER: Nicht genug Speicherplatz verfügbar!\n\nBenötigt: ${size}MB\nVerfügbar: ${available_space_mb}MB\n\nBitte gib eine kleinere Größe ein." 12 65
                create_swap
                return
            fi

            # Erstelle Swap mit Error-Handling
            if ! sudo fallocate -l ${size}M /swapfile 2>/dev/null; then
                whiptail --title "Fehler" --msgbox "FEHLER: Swap-Datei konnte nicht erstellt werden.\n\nMögliche Ursachen:\n- Nicht genug Speicherplatz\n- Keine Berechtigung\n- Dateisystem unterstützt fallocate nicht" 12 65
                menu
                return
            fi

            if ! sudo chmod 600 /swapfile 2>/dev/null; then
                whiptail --title "Fehler" --msgbox "FEHLER: Berechtigungen konnten nicht gesetzt werden." 10 60
                sudo rm -f /swapfile
                menu
                return
            fi

            if ! sudo mkswap /swapfile 2>/dev/null; then
                whiptail --title "Fehler" --msgbox "FEHLER: Swap konnte nicht formatiert werden." 10 60
                sudo rm -f /swapfile
                menu
                return
            fi

            if ! sudo swapon /swapfile 2>/dev/null; then
                whiptail --title "Fehler" --msgbox "FEHLER: Swap konnte nicht aktiviert werden.\n\nPrüfe ob bereits Swap aktiv ist mit: swapon --show" 12 65
                sudo rm -f /swapfile
                menu
                return
            fi

            whiptail --title "Swap-Speicher erstellt" --msgbox "Swap-Speicher wurde erfolgreich erstellt und aktiviert.\n\nGröße: ${size}MB" 10 60
            menu
        else
            whiptail --title "Das ist keine Zahl" --msgbox "Ungültige Eingabe. Bitte gebe eine Zahl ein." 10 60
            create_swap
        fi
    else
        whiptail --title "Abgebrochen" --msgbox "Der Vorgang wurde abgebrochen." 10 60
        menu
    fi
}

# Hauptprogramm
whiptail --title "Swap-Speicher-Management" --msgbox "Willkommen zum Swap-Speicher-Management-Script!\nSwap-Speicher wird zur Auslagerung von RAM-Inhalten verwendet, wenn der physische Speicher erschöpft ist." 10 60

check_swap
