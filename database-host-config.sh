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
whiptail --title "🎉 Database Host angelegt" --msgbox "Der Database Host wurde erfolgreich erstellt und steht nun zur Einrichtung zur Verfügung. Navigiere nun in deinem Admin Panel auf das Menü namens 'Alle Datenbanken'. Klicke auf Erstellen, wenn du soweit bist, bestätige es DANN ERST mit ENTER. Dir werden dann einmalig die angelegten Zugangsdaten angezeigt, die hinzugefügt werden können." 20 78

# Zugangsdaten des Database Host
clear
whiptail --title "🔐 Zugangsdaten des Database Host" --msgbox "Hier sind die Zugangsdaten des MySQL Host:\n\nName: (Darfst du selbst benennen)\nHost: ${IP_ADDRESS}\nPort: 3306\nBenutzername: ${USERNAME}\n\n⚠️  WICHTIG: Das Passwort wird im nächsten Schritt in der Konsole angezeigt!\n\nUnter 'Linked Node' musst du nichts verändern.\n\nDrücke ENTER um fortzufahren und das Passwort zu sehen." 20 78

# Passwort in der Konsole ausgeben
clear
echo ""
echo ""
echo "PASSWORT FREIGEGEBEN - - - - - - - - - - - - - - -"
echo -e "\nPasswort zum Kopieren:"
echo -e "$PASSWORD\n" | /usr/games/lolcat
echo "Sobald du es kopiert und eingefügt hast, schreibe 'Gespeichert' und drücke ENTER."
echo ""
while true; do
    echo -n "-> Bestätigung: "
    read -r confirmation
    if [ "$confirmation" = "Gespeichert" ]; then
        break
    else
        echo "❌ Bitte schreibe genau 'Gespeichert' (Groß-/Kleinschreibung beachten)"
    fi
done

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

