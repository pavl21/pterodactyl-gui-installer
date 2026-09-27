# GermanDactyl Setup – Pterodactyl TUI-Installer (inoffiziell)

Installiert das [Pterodactyl Panel](https://pterodactyl.io/) samt deutscher Übersetzung ([GermanDactyl](https://github.com/pavl21/GermanDactyl)) und auf Wunsch Wings – über eine Textoberfläche (TUI) im Terminal. Liegen Panel und Wings auf demselben Server, ist danach alles fertig eingerichtet: Node, Verbindung, Ports für Gameserver, SSL-Zertifikate und Firewall. Du kannst sofort deinen ersten Gameserver anlegen.

Das Skript ist eigenständig: Panel und Wings werden nach der offiziellen Dokumentation eingerichtet, fremde Installationsskripte werden nicht mehr ausgeführt.

## Start

```bash
sudo bash -c "$(curl -sSL https://setup.germandactyl.de/)"
```

Ist Pterodactyl bereits installiert, öffnet sich stattdessen die Verwaltung. Dort findest du Problembehandlung, Updates, Wings, Blueprint, phpMyAdmin, Backups, Database-Host, SSH-Loginseite, Swap und die Deinstallation.

## Voraussetzungen

- Debian 11, 12 oder 13 bzw. Ubuntu 22.04, 24.04 oder 26.04 (amd64 oder arm64)
- Root-Rechte
- Eine Domain bzw. Subdomain, deren A-Eintrag auf den Server zeigt. Bei Cloudflare muss der Proxy dafür deaktiviert sein.

## Was wird eingerichtet?

- **Pakete:** PHP 8.3 (über packages.sury.org), MariaDB, Redis, nginx, Composer und Certbot
- **Panel:** Pterodactyl Panel mit Cronjob und Queue-Dienst (`pteroq`), SSL über Let's Encrypt inklusive automatischer Erneuerung
- **Deutsche Übersetzung (GermanDactyl):**
  - Gibt es für die neueste Pterodactyl-Version bereits einen Patch, wird er automatisch angewendet.
  - Sonst kannst du wählen: die neueste Version auf Englisch oder die neueste übersetzte Version.
- **Wings (optional):**
  - Docker, Wings, eine automatisch angelegte Node, die Konfiguration und ein Portbereich für Gameserver.
  - Läuft Wings auf einem anderen Server, fügst du nur den Befehl aus dem Panel ein ("Generate Token").
- **Absicherung (optional):**
  - UFW-Firewall; dein SSH-Port wird automatisch freigegeben.
  - fail2ban
  - Automatische Sicherheitsupdates
  - Absicherung der MariaDB
- **Blueprint (optional):** Das Framework für Erweiterungen und Themes ([blueprint.zip](https://blueprint.zip)). Es wird bei Panel-Updates automatisch erneut angewendet.

## Voreinstellungen

- Die Datenbank für das Panel wird automatisch mit einem zufälligen Passwort angelegt. Diese Datenbank darf **nicht** als Database-Host verwendet werden – dafür gibt es in der Verwaltung einen eigenen Menüpunkt.
- **Telemetrie:** Bei der Installation wirst du gefragt, ob das Panel anonyme Nutzungsdaten (z. B. Versionen und Anzahl der Server) an die Pterodactyl-Entwickler senden darf ([Details](https://pterodactyl.io/panel/1.0/additional_configuration.html#telemetry)).
- **Log-Dateien:** Alle Schritte werden in `/var/log/germandactyl-setup/` protokolliert.

## Hinweis

Dies ist ein inoffizielles Projekt. Die Nutzung erfolgt auf eigene Verantwortung. Erstelle vor Updates und Änderungen immer ein Backup, zum Beispiel über die Backup-Verwaltung.

Pelican (der Nachfolger von Pterodactyl) kann ebenfalls installiert werden. Pelican ist noch eine Beta-Version.
