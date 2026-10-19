# GermanDactyl Setup – Pterodactyl TUI-Installer (inoffiziell)

Installiert das [Pterodactyl Panel](https://pterodactyl.io/) samt deutscher Übersetzung ([GermanDactyl](https://github.com/pavl21/GermanDactyl)) und auf Wunsch Wings – über eine Textoberfläche (TUI) im Terminal. Liegen Panel und Wings auf demselben Server, ist danach alles fertig eingerichtet: Node, Verbindung, Ports für Gameserver, SSL-Zertifikate und Firewall. Du kannst sofort deinen ersten Gameserver anlegen.

Das Skript ist eigenständig: Panel und Wings werden nach der offiziellen Dokumentation eingerichtet, fremde Installationsskripte werden nicht mehr ausgeführt.

## Start

```bash
sudo bash -c "$(curl -sSL https://setup.germandactyl.de/)"
```

Im Express-Modus brauchst du nur deine Domain, alles andere wird automatisch mit sicheren Standardwerten eingerichtet (anonymes Zertifikat, Benutzer admin, Firewall, fail2ban, Sicherheitsupdates, tägliche Backups).

Ist Pterodactyl bereits installiert, öffnet sich stattdessen die Verwaltung. Dort findest du Hilfe & Analyse, Updates, Backups, Wings und Ports, Blueprint, phpMyAdmin, Database-Host, Firewall, fail2ban, SSH-Loginseite, Swap und die Deinstallation.

Nach der Installation startest du die Verwaltung jederzeit mit dem Befehl `germandactyl` bzw. kurz `gmd` oder `gd` (`gmd` und `gd` nur, wenn es auf dem Server noch keinen gleichnamigen Befehl gibt).

## Kurzbefehle

Für häufige Aufgaben musst du das Menü nicht öffnen. Alle Befehle funktionieren auch mit `germandactyl` und `gd`, etwa `germandactyl update panel`.

| Befehl | Was passiert |
| --- | --- |
| `gmd` | Öffnet die Verwaltung |
| `gmd analyse` | Startet die Analyse mit Dialogen |
| `gmd analyse --text` | Analyse als reiner Text, ohne Dialoge |
| `gmd analyse --text --fix` | Analyse als Text und behebt alle automatisch behebbaren Probleme |
| `gmd backup` | Öffnet die Backup-Verwaltung |
| `gmd update` | Öffnet das Update-Menü |
| `gmd update panel` / `wings` / `system` | Aktualisiert direkt das Panel, Wings oder die System-Pakete |
| `gmd ssl` | Öffnet die SSL-Zertifikatsverwaltung |
| `gmd wings` | Öffnet die Wings-Verwaltung |
| `gmd firewall` | Öffnet die Firewall-Verwaltung |
| `gmd logs` | Zeigt die Logs |
| `gmd status` | Zeigt die Statuszeile |
| `gmd hilfe` | Zeigt alle Kurzbefehle |

## Voraussetzungen

- Debian 12 oder 13 bzw. Ubuntu 22.04, 24.04 oder 26.04 (amd64 oder arm64)
- Root-Rechte
- Eine Domain bzw. Subdomain, deren A-Eintrag auf den Server zeigt. Bei Cloudflare kann der Proxy (orange Wolke) für das Panel an bleiben, wenn du bei der Installation einen Cloudflare API-Token (Berechtigungen Zone:DNS:Edit und Zone:Zone:Read) verwendest – das Zertifikat wird dann per DNS-Challenge ausgestellt. Für Wings muss der Proxy aus sein (DNS only), dafür ist bei aktivem Proxy eine eigene Subdomain nötig.

## Was wird eingerichtet?

- **Pakete:** PHP 8.3 (über packages.sury.org), MariaDB, Redis, nginx, Composer und Certbot
- **Panel:** Pterodactyl Panel mit Cronjob und Queue-Dienst (`pteroq`), SSL über Let's Encrypt inklusive automatischer Erneuerung
- **Deutsche Übersetzung (GermanDactyl):**
  - Gibt es für die neueste Pterodactyl-Version bereits einen Patch, wird er automatisch angewendet.
  - Sonst kannst du wählen: die neueste Version auf Englisch oder die neueste übersetzte Version.
- **Wings (optional):**
  - Docker, Wings, eine automatisch angelegte Node, die Konfiguration und ein Portbereich für Gameserver.
  - Läuft Wings auf einem anderen Server, fügst du nur den Befehl aus dem Panel ein („Generate Token“).
- **Absicherung (optional):**
  - UFW-Firewall; dein SSH-Port wird automatisch freigegeben.
  - fail2ban
  - Automatische Sicherheitsupdates
  - Absicherung der MariaDB
- **Automatische Backups (optional):** täglich, inkrementell und verschlüsselt mit restic – Panel, alle Datenbanken (auch die der Gameserver), Konfigurationen und auf Wunsch die Gameserver-Daten. Das Passwort des Backup-Archivs wird am Ende angezeigt; bewahre es sicher auf, ohne es lassen sich die Backups nicht wiederherstellen.
- **Blueprint (optional):** Das Framework für Erweiterungen und Themes ([blueprint.zip](https://blueprint.zip)). Es wird bei Panel-Updates automatisch erneut angewendet.

## Voreinstellungen

- Die Datenbank für das Panel wird automatisch mit einem zufälligen Passwort angelegt. Diese Datenbank darf **nicht** als Database-Host verwendet werden – dafür gibt es in der Verwaltung einen eigenen Menüpunkt.
- **Telemetrie:** Bei der Installation wirst du gefragt, ob das Panel anonyme Nutzungsdaten (z. B. Versionen und Anzahl der Server) an die Pterodactyl-Entwickler senden darf ([Details](https://pterodactyl.io/panel/1.0/additional_configuration.html#telemetry)).
- **E-Mail-Adresse ist optional:** Ohne Angabe wird das Zertifikat ohne Kontakt-Adresse ausgestellt und das Administrator-Konto heißt `admin@<deine-domain>`.
- **Log-Dateien:** Alle Schritte werden in `/var/log/germandactyl-setup/` protokolliert.

## Hinweis

**Testphase:** GermanDactyl Setup befindet sich noch in der Testphase. Es können jederzeit unerwartete Fehler auftreten, auch bei Funktionen, die bereits stabil wirken. Setze es deshalb zuerst auf einem Testserver ein und erstelle vor Updates und Änderungen immer ein Backup, zum Beispiel über die Backup-Verwaltung. Fehler melde bitte als [Issue](https://github.com/pavl21/pterodactyl-gui-installer/issues).

Dies ist ein inoffizielles Projekt. Die Nutzung erfolgt auf eigene Verantwortung.

Pelican (der Nachfolger von Pterodactyl) kann ebenfalls installiert werden – als Panel mit Wings auf demselben Server oder als reiner Wings-Server für ein Pelican-Panel auf einem anderen Server. Pelican ist noch eine Beta-Version; die Verwaltungsfunktionen (Backups, Blueprint, phpMyAdmin usw.) sind nur für Pterodactyl vorgesehen.
