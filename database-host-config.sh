#!/bin/bash

# Sicherheitshinweis anzeigen
if ! whiptail --title "⚠️ Sicherheitshinweis" --yesno "Dieses Script beinhaltet möglicherweise ein Sicherheitsrisiko, wofür du alleine verantwortlich bist wenn du keine weiteren Sicherheitsvorkehrungen triffst.\n\nDurch diesen Script wird ein Datenbank-Host angelegt, die für alle öffentlich erreichbar ist. Der direkte Zugriff verweigert nur das nötige Passwort.\n\nUm es unautorisierten Nutzern schwer zu machen, wird ein 256-stelliges Passwort verwendet. Das Passwort wirst du nach Abschluss der Konfiguration nicht mehr brauchen.\n\nDiese wird rein zufällig generiert.\n\nMöchtest du fortfahren?" 22 78; then
    echo "Benutzer hat abgebrochen."
    curl -sSL https://setup.germandactyl.de/ | sudo bash -s --
    exit 1
fi

clear
echo ""
echo ""
echo "### Passwortgenerierung gestartet ###"
sleep 0.5
### Prüfe, ob notwendige Pakete vorhanden sind* ###
apt install jq curl lolcat -y

# Funktion zur Passwortgenerierung
generate_password() {
    tr -dc '[:alnum:]' </dev/urandom | head -c 256
}

# Fortschrittsanzeige-Funktion mit Passwortanzeige - Is unnötig, aber funny. :D
show_progress() {
    for ((i = 0; i <= 100; i++)); do
        sleep 0.125  # Kurze Wartezeit zwischen den Iterationen
        password=$(generate_password)
        echo $i
        echo "XXX"
        echo "Generiere Passwort: $password"
    done
}

{
    show_progress
} | whiptail --title "🔑 Passwortgenerator läuft gerade" --gauge "Generiere Passwort..." 8 78 0

PASSWORD=$(generate_password)
echo "Passwort wurde generiert: $PASSWORD"
sleep 0.5

echo "### Benutzernamengenerierung gestartet ###"
USERNAME=$(curl -s 'https://randomuser.me/api/?nat=de' | jq -r '.results[0].name.first + .results[0].name.last' | tr -d 'äöü')
echo "Benutzername generiert: $USERNAME"
sleep 0.5

echo "### Ermittlung der öffentlichen IP-Adresse ###"
IP_ADDRESS=$(curl -s http://ipinfo.io/ip)
echo "Öffentliche IP-Adresse: $IP_ADDRESS"
sleep 0.5

echo "### MySQL-Benutzer und Berechtigungen werden erstellt ###"
sudo mysql -e "CREATE USER '${USERNAME}'@'${IP_ADDRESS}' IDENTIFIED BY '${PASSWORD}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON *.* TO '${USERNAME}'@'${IP_ADDRESS}' WITH GRANT OPTION;"
sudo mysql -e "FLUSH PRIVILEGES;"
echo "MySQL-Benutzer und Berechtigungen erstellt."
sleep 0.5

echo "### MySQL-Konfiguration wird angepasst und MySQL neu gestartet ###"
echo -e "[mysqld]\nbind-address=0.0.0.0" | sudo tee -a /etc/mysql/my.cnf
sudo systemctl restart mysql
echo "MySQL-Konfiguration angepasst und MySQL neu gestartet."
sleep 0.5

# Zugangsdaten anzeigen
clear
whiptail --title "🎉 Database Host angelegt" --msgbox "Der Database Host wurde erfolgreich erstellt und steht nun zur Einrichtung zur Verfügung. Navigiere nun in deinem Admin Panel auf das Menü namens 'Alle Datenbanken'. Klicke auf Erstellen, wenn du soweit bist, bestätige es DANN ERST mit ENTER. Dir werden dann die angelegten Zugangsdaten angezeigt." 16 78

# Erstelle temporäre Datei für Passwort (sicherer als nur Console)
TEMP_PW_FILE="/tmp/db_password_$(date +%s).txt"
echo "$PASSWORD" > "$TEMP_PW_FILE"
chmod 600 "$TEMP_PW_FILE"

# Zugangsdaten in whiptail anzeigen (bleibt sichtbar bis Enter)
whiptail --title "🔐 Zugangsdaten des Database Host" --msgbox "Hier sind die Zugangsdaten des MySQL Host:\n\nName: (Darfst du selbst benennen)\nHost: ${IP_ADDRESS}\nPort: 3306\nBenutzername: ${USERNAME}\n\nPasswort-Datei: ${TEMP_PW_FILE}\n\nDas Passwort wird auf der nächsten Seite angezeigt.\n\nUnter Linked Node musst du nichts verändern.\nDrücke Enter um fortzufahren..." 20 78

# Passwort direkt in whiptail anzeigen (scrollt nicht weg!)
whiptail --title "🔐 PASSWORT - BITTE KOPIEREN" --msgbox "BENUTZERNAME:\n${USERNAME}\n\nPASSWORT (256 Zeichen):\n${PASSWORD}\n\n\nDas Passwort ist auch gespeichert in:\n${TEMP_PW_FILE}\n\nDu kannst es mit 'cat ${TEMP_PW_FILE}' erneut anzeigen.\n\nKOPIERE DAS PASSWORT JETZT!\nDrücke Enter wenn du fertig bist." 24 80

# Zusätzlich in Console ausgeben (als Backup)
clear
echo "=============================================="
echo "   DATABASE HOST ZUGANGSDATEN"
echo "=============================================="
echo ""
echo "Host:         ${IP_ADDRESS}"
echo "Port:         3306"
echo "Benutzername: ${USERNAME}"
echo ""
echo "Passwort:"
echo "----------------------------------------------"
echo "$PASSWORD"
echo "----------------------------------------------"
echo ""
echo "Temporäre Datei: ${TEMP_PW_FILE}"
echo ""
echo "=============================================="
echo ""
echo "Drücke Enter nachdem du das Passwort kopiert"
echo "und im Panel eingefügt hast..."
read -r

# Frage ob Passwort nochmal angezeigt werden soll
if ! whiptail --title "Passwort gespeichert?" --yesno "Hast du das Passwort erfolgreich im Panel eingefügt?" 10 60; then
    whiptail --title "🔐 PASSWORT NOCHMAL" --msgbox "PASSWORT:\n\n${PASSWORD}\n\nOder öffne: ${TEMP_PW_FILE}" 18 80
    echo ""
    echo "Passwort wird nochmal angezeigt:"
    echo "$PASSWORD"
    echo ""
    echo "Drücke Enter wenn fertig..."
    read -r
fi

# Temporäre Datei löschen
rm -f "$TEMP_PW_FILE" 2>/dev/null

# Marker für das Ende dieses Skriptteils
echo -e "\n### Passwortgenerierung und Anzeige abgeschlossen ###\n"


# Erfolgsmeldung und Datenlöschung bei Fehlschlag, wenn man sagt will nicht
if ! whiptail --title "✅ Erreichbarkeit prüfen" --yesno "Hat die Einrichtung des Database Hosts geklappt?" 20 78; then
    whiptail --title "❗ Fehler" --msgbox "Bitte überprüfe die Eingaben auf mögliche Schreibfehler und versuche es erneut. Die Daten werden dann aus Sicherheitsgründen gelöscht." 20 78

    clear
    echo ""
    echo ""
    echo "### Einrichtung fehlgeschlagen ###"
    echo "Benutzer $USERNAME und zugehörige Daten werden gelöscht..."
    sleep 0.5

    # Befehl zum Löschen des Datenbankbenutzers
    sudo mysql -e "DROP USER '${USERNAME}'@'${IP_ADDRESS}';"
    sudo mysql -e "FLUSH PRIVILEGES;"

    echo "Datenbankbenutzer $USERNAME wurde gelöscht."
    whiptail --title "Vorgang zurückgesetzt" --msgbox "Da der Vorgang laut Eingabe nicht erfolgreich war, wurden sämtliche Änderungen rückgänig gemacht." 20 78
else
    whiptail --title "🎊 Erfolg" --msgbox "Super! Nun ist der Database Host eingerichtet und du kannst deine eigenen Datenbanken erstellen." 20 78
fi

clear
echo ""
echo ""
echo "================== Aufgabe beendet =================="
sleep 1
sudo bash -c "$(curl -sSL https://setup.germandactyl.de/)"

