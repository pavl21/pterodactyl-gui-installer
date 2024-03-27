#!/bin/bash

# Funktion zur Installation von phpMyAdmin im Hintergrund
function install_phpmyadmin() {
    cd /var/www/pterodactyl/public/ && \
    mkdir phpmyadmin && \
    cd phpmyadmin && \
    wget https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-all-languages.zip -q && \
    unzip -qq phpMyAdmin-5.2.1-all-languages.zip && \
    mv phpMyAdmin-5.2.1-all-languages/* . && \
    rm -rf phpMyAdmin-5.2.1-all-languages phpMyAdmin-5.2.1-all-languages.zip && \
    mkdir tmp && \
    chmod -R 777 tmp && \
    create_config
}

# Funktion zur Erstellung des Datenbankbenutzers im Hintergrund
function create_database_user() {
    username="Admin$((RANDOM % 100000))"
    password=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
    mysql -u root -e "CREATE USER '$username'@'localhost' IDENTIFIED BY '$password'; GRANT ALL PRIVILEGES ON *.* TO '$username'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;" > /dev/null 2>&1
    echo "Benutzername: $username\nPasswort: $password"
}

# Funktion zur Erstellung der Konfigurationsdatei
function create_config() {
    blowfish_secret=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
    cat > /var/www/pterodactyl/public/phpmyadmin/config.inc.php <<EOL
<?php
\$cfg['blowfish_secret'] = '$blowfish_secret';
?>
EOL
}

# Prüfe, ob phpMyAdmin bereits installiert ist
if [ -d "/var/www/pterodactyl/public/phpmyadmin" ]; then
    whiptail --title "🚫 phpMyAdmin bereits installiert" --msgbox "Du hast anscheinend schon phpMyAdmin laufen, die Installation wird abgebrochen." 10 60
    curl -sSL https://setup.germandactyl.de/ | sudo bash -s --
    exit
fi

# Erster Schritt: Willkommensnachricht
if whiptail --title "👋 phpMyAdmin Installation" --msgbox "Willkommen in der Installation von phpMyAdmin! Bevor wir weitermachen, möchten wir dich auf Folgendes hinweisen:\n\n- Deine Datenbank ist öffentlich zugänglich, sobald man die Zugangsdaten kennt.\n- Du solltest sichere Passwörter nutzen!\n- Dein Root-Passwort muss sicher sein! Wenn nicht, erhalten andere möglicherweise Zugang." 15 60 --ok-button "Weiter" --cancel-button "Abbrechen"; then
    # Installationsschritte im Hintergrund ausführen und Fortschritt anzeigen
    { for ((i=0; i<=100; i+=20)); do sleep 1; echo $i; done; install_phpmyadmin; } | whiptail --title "📦 Installation - phpMyAdmin" --gauge "Bitte warten, die Installation wird durchgeführt..." 6 60 0

    # Dritter Schritt: Datenbankbenutzer erstellen
    database_credentials=$(create_database_user)

    # Überprüfen und eventuell wiederholen, bis die Zugangsdaten akzeptiert wurden
    while true; do
        # Vierter Schritt: Zugangsdaten anzeigen
        whiptail --title "🔑 Datenbank Zugangsdaten" --msgbox "Hier sind die Zugangsdaten für den Admin-Zugang in phpMyAdmin:\n\n$database_credentials" 15 60

        if whiptail --title "Zugangsdaten überprüfen" --yesno "Funktionieren die Zugangsdaten?" 10 60; then
            if whiptail --title "Zugangsdaten speichern" --yesno "Hast du die Zugangsdaten gespeichert? Diese Zugangsdaten werden nicht noch einmal angezeigt, wenn du es bestätigst!" 10 60; then
                break
            else
                continue
            fi
        else
            database_credentials=$(create_database_user)
        fi
    done

    # Sechster Schritt: Einrichtung abgeschlossen
    whiptail --title "🎉 Einrichtung abgeschlossen" --msgbox "Du kannst nun phpMyAdmin nutzen. Um eine bestimmte Datenbank zu öffnen, kannst du die dort generierten Zugangsdaten verwenden." 10 60
else
    # Installation abgebrochen
    whiptail --title "❌ Installation abgebrochen" --msgbox "Die Installation von phpMyAdmin wurde abgebrochen." 10 60
fi

# Abschließendes Skript ausführen
curl -sSL https://setup.germandactyl.de/ | sudo bash -s --

