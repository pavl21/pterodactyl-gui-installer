#!/bin/bash

# Funktion zur Überprüfung, ob Swap bereits vorhanden ist
check_swap() {
    if [[ -e /swapfile ]]; then
        whiptail --title "Swap-Speicher existiert bereits" --yesno "Swap-Speicher ist bereits vorhanden. Möchtest du den vorhandenen Swap-Speicher entfernen oder anpassen?" 10 60
        response=$?
        if [ $response -eq 0 ]; then
            sudo swapoff /swapfile
            sudo rm /swapfile
            whiptail --title "Swap-Speicher entfernt" --msgbox "Der vorhandene Swap-Speicher wurde entfernt." 10 60
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
            sudo fallocate -l ${size}M /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
            whiptail --title "Swap-Speicher erstellt" --msgbox "Swap-Speicher wurde erfolgreich erstellt und aktiviert." 10 60
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
