#!/bin/bash

# Überprüft, ob der Pfad /etc/motd.sh existiert
if [ -f /etc/motd.sh ]; then
    if whiptail --title "🛑 Custom SSH Login-Page bereits aktiv" --yesno "Du verwendest bereits unsere SSH Login-Page, möchtest du es entfernen? Dadurch wird die vorab eingestellte Version wiederhergestellt." 12 78; then
        sudo rm /etc/motd.sh
        sudo sed -i '/\/etc\/motd.sh/d' /etc/profile
        whiptail --title "✅ SSH Login-Page wiederhergestellt" --msgbox "Deine voreingestellte Ansicht wurde nun wiederhergestellt." 8 78
        curl -sSL https://setup.germandactyl.de/ | sudo bash -s --
        exit 0
    else
        curl -sSL https://setup.germandactyl.de/ | sudo bash -s --
        exit 0
    fi
fi

# Informationsfenster zu Beginn
if whiptail --title "🐾 GermanDactyl SSH-Login" --yesno "Wenn du diesen Server nur für Pterodactyl verwendest, ist dieser custom SSH Login für dich eventuell von Vorteil.\nDu bekommst dort Informationen des Servers angezeigt, wie der aktuelle Stand ist, sobald du dich anmeldest.\nDu kannst es jederzeit rückgängig machen, die aktuelle Anzeige wird als Kopie gespeichert.\nMöchtest du fortfahren?" 14 78; then
    echo "Installiere benötigte Pakete..."
    sudo apt-get install lolcat figlet vnstat jq -y

    echo "Erstelle die Datei /etc/motd.sh..."
    wget https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/motd.sh -O /etc/motd.sh

    echo "Setze die Rechte, damit es gestartet wird..."
    chmod 777 /etc/motd.sh

    echo "Starter festlegen..."
    sudo sed -i '$ a /etc/motd.sh' /etc/profile

    whiptail --title "🎉 Custom SSH Login-Page aktiviert" --msgbox "Die Anmeldeseite, wenn du dich in SSH anmeldest, wurde angepasst. Sobald du das Script verlässt, wirst du es sehen. Wenn es dir nicht gefallen sollte, kannst du es über denselben Weg jederzeit wieder entfernen." 12 78
    /etc/motd.sh
else
    curl -sSL https://setup.germandactyl.de/ | sudo bash -s --
    exit 0
fi
