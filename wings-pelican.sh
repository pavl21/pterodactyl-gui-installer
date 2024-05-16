#!/bin/bash

# Systemvoraussetzungen überprüfen
echo "Überprüfe Systemvoraussetzungen..."
kernel=$(uname -r)
if [[ "$kernel" != *"-grs-ipv6-64" && "$kernel" != *"-mod-std-ipv6-64" ]]; then
    echo "Kernel wird unterstützt."
else
    echo "WARNUNG: Möglicherweise nicht unterstützter Kernel: $kernel"
fi

# Überprüfen der Virtualisierungstechnologie
virt_type=$(systemd-detect-virt)
if [[ "$virt_type" != "openvz" && "$virt_type" != "lxc" ]]; then
    echo "Virtualisierungstechnologie wird unterstützt."
else
    echo "WARNUNG: Möglicherweise nicht unterstützte Virtualisierungstechnologie: $virt_type"
fi

# Systemhersteller überprüfen
manufacturer=$(sudo dmidecode -s system-manufacturer)
echo "Systemhersteller: $manufacturer"

echo "Überprüfung abgeschlossen. Die Installation kann fortgesetzt werden. 🚀"
sleep 5
clear

# Funktion zur Aktualisierung des Fortschrittsbalkens mit Whiptail
update_progress() {
    percentage=$1
    message=$2
    echo -e "XXX\n$percentage\n$message\nXXX"
}

# Installationsprozess mit Fortschrittsbalken
{
    update_progress 2 "Vorbereitung der Installation..."
    sleep 1
    panel_domain=$(cat /var/.panel_domain) > /dev/null 2>&1
    update_progress 15 "Docker wird installiert..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable sh > /dev/null 2>&1
    update_progress 30 "Docker wird aktiviert..."
    sudo systemctl enable --now docker > /dev/null 2>&1
    update_progress 65 "Wings-Verzeichnis wird erstellt..."
    sudo mkdir -p /etc/pelican
    sleep 1
    update_progress 70 "Wings-Code wird heruntergeladen..."
    curl -L -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")" > /dev/null 2>&1
    sleep 1
    update_progress 85 "Berechtigungen werden zugewiesen..."
    sudo chmod u+x /usr/local/bin/wings > /dev/null 2>&1
    systemctl enable --now wings > /dev/null 2>&1
    sleep 1
} | whiptail --title "Wings wird vorbereitet" --gauge "Bitte warten..." 7 50 0

# Systemd-Dienstdatei erstellen
cat <<EOF > /etc/systemd/system/wings.service
[Unit]
Description=Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Konfigurationsdatei einrichten
whiptail --title "Config integrieren" --msgbox "Wings wurde vorbereitet, nun wird eine Config benötigt. Diese Config wird erstellt, indem du eine Node im Panel erstellst. In dem Falle wird dieser Server als Node aufgesetzt.\n\nFolgende Angaben kannst du integrieren:\nDomain Name: Domain vom Panel\nPort: 8080\n\nNach dem Erstellen der Node wird die Config erstellt. Im folgenden Fenster kannst du sie einfügen. Bestätige, wenn du fortfahren kannst." 17 90

while true; do
    clear
    echo "HANDLUNG NOTWENDIG - - - - - - - - - - -"
    echo ""
    echo ""
    echo "Füge bitte die Konfiguration im folgenden Editor ein, der Editor wird geöffnet..."
    # Pfad zur Datei definieren
    file_path="/etc/pelican/config.yml"

    # Startet den nano Editor zur Bearbeitung der Datei
    nano "$file_path"

    # Überprüfen, ob die Datei Inhalt hat
    if [ -s "$file_path" ]; then
        clear
        systemctl daemon reload
        systemctl restart nginx
        systemctl restart wings
        whiptail --title "Wings ist betriebsbereit" --msgbox "Wings ist nun online und bereit für die Nutzung. Beachte bitte, dass das Pelican Panel und Wings instabil sein kann. " 10 60
        clear
        exit 0
        clear
    else
        whiptail --title "Datenstruktur fehlt" --msgbox "Die Konfigurationsdatei darf nicht leer sein. Bitte fülle sie aus." 10 50
    fi
done
