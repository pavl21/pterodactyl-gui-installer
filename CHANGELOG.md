# Changelog

## [Unveröffentlicht] – Oktober 2026

### Behobene Fehler

- Die automatische Zertifikatserneuerung war bei der Installation zwar eingerichtet, lief aber nie; das Setup startet den Timer jetzt, und die Analyse prüft, ob er wirklich läuft (sonst laufen deine Zertifikate nach 90 Tagen ab).
- Nach einem Panel-Update konnte die deutsche Übersetzung veraltet bleiben, weil Reste der alten Übersetzung das Anwenden blockierten; solche Reste werden jetzt gesichert und ersetzt.
- Lassen sich Übersetzungsteile nicht sauber anwenden (das betrifft vor allem Installationen mit Blueprint), versucht das Setup sie ein zweites Mal mit etwas Unschärfe. Stellen, die auch damit nicht passen, bleiben englisch und stehen in einer Liste, die das Setup nennt.
- Ein fehlgeschlagenes Panel-Update lässt das Panel nicht halbfertig online: Es bleibt im Wartungsmodus, und bei geplanten Updates wird es aus der automatischen Sicherung zurückgespielt.
- Schlägt der Datenbank-Teil eines automatischen Backups fehl, wird der Stand als unvollständig gekennzeichnet und verdrängt keine vollständigen Backups mehr.
- Vor einer Wiederherstellung wird der aktuelle Datenbankstand gesichert; gelingt das nicht, bricht die Wiederherstellung ab, ohne etwas zu verändern.
- Pterodactyl 2.x wird nicht als neueste Version angeboten, und ein Downgrade des Panels wird abgelehnt, damit das Panel nicht beschädigt wird. Wings wird nur in der Hauptversion aktualisiert, die zum Panel passt.
- Schlägt die Pelican-Installation fehl, nachdem das Panel fertig ist, gehen die Zugangsdaten nicht verloren: Sie werden beim nächsten Start angezeigt.
- Frisch gestartete Server sperren oft für eine Weile die Paketverwaltung; das Setup wartet jetzt bis zu 20 Minuten mit einer Statusmeldung, und die täglichen Update-Timer werden für die Installation angehalten.
- Wird das Setup abgebrochen (Strg+C oder abgerissene SSH-Verbindung), nimmt es seine temporären Einstellungen wieder zurück, etwa den Zusatz-Swap für den Build.
- Haben Panel und Pelican gleichzeitig eine nginx-Konfiguration mit doppelter Angabe, brach nginx ab; die Angabe steht jetzt in jedem Serverblock. Schlägt der nginx-Test fehl, wird die vorherige Konfiguration wiederhergestellt, damit nginx weiterläuft.
- Kollidiert das Docker-Netz für Wings mit einem bestehenden Netz, wählt das Setup ein freies und trägt es in die Wings-Konfiguration ein.
- Die Swap-Einrichtung funktioniert jetzt auch auf btrfs und in LXC-Containern.
- Die HTTP/2-Einstellung für nginx ab Version 1.25.1 wird korrekt gesetzt.

### Neue Funktionen

- Geplante Updates: Panel und Wings können nachts automatisch aktualisiert werden. Die Funktion ist standardmäßig aus und wird im Menü mit einer Warnung eingeschaltet; ein laufendes Backup wird abgewartet.
- Automatische Updates überspringen das Panel, wenn du eigene Änderungen daran hast (z. B. Themes oder Plugins), außer du hast "wieder anwenden" gewählt. Fehlgeschlagene Versionen werden nicht jede Nacht erneut versucht.
- Vor einem Panel-Update vergleicht das Setup dein Panel mit dem Original und zeigt eigene Änderungen an. Du entscheidest, ob sie gesichert und nach dem Update wieder angewendet werden, das Update ohne Übernahme läuft oder du abbrichst.
- Vor jedem Panel-Update wird automatisch eine Sicherung von Dateien und Datenbank angelegt.
- Blueprint-Dateien zählen dabei nicht als eigene Änderungen; das Setup meldet nur, dass Blueprint installiert ist und nach dem Update automatisch neu angewendet wird.
- Das Wings-Update im Menü prüft, ob die neue Version zu deinem Panel passt, sichert die alte Version und testet die neue. Schlägt der Test fehl, wird die alte Version zurückgespielt.
- Die Backups sichern jetzt zusätzlich die Datenbank-Benutzer mit ihren Rechten, die Gameserver-Backups, die Systemdienste, die Crontabs sowie die Konfiguration von MariaDB, Redis, Firewall und fail2ban.
- Neben einem lokalen Ordner kannst du Backups auch auf einen SFTP-Server, in einen S3-Speicher (z. B. Amazon S3, Backblaze B2, Wasabi oder MinIO) oder auf einen rest-server schreiben; das Setup prüft die Verbindung, bevor es das Ziel übernimmt.
- Die Hetzner Storage Box ist als eigenes Backup-Ziel wählbar: Benutzername und Passwort einmal eingeben, das Setup erzeugt den SSH-Schlüssel, hinterlegt ihn auf der Box, legt den Ordner an und prüft die Verbindung; das Passwort wird nicht gespeichert.
- Ein lokales Backup-Ziel auf derselben Festplatte wie das System wird mit einer Warnung versehen.
- Die Wiederherstellung kann die Konfiguration (nginx, Zertifikate, Wings und Panel) als eigenen Punkt zurückspielen; die aktuelle Konfiguration wird vorher gesichert.
- Während eines Datenbank-Imports werden Queue-Worker und Cron angehalten, damit nichts in die Datenbank schreibt.
- Backups werden wöchentlich auf Lesbarkeit geprüft (Stichprobe von 10 % der Daten); das Ergebnis steht in der Statusanzeige und in der Analyse.
- Die Analyse prüft die Zertifikatserneuerung tatsächlich: Erneuerungskonfiguration je Zertifikat, Ergebnis des letzten Laufs, Restlaufzeit, Firewall-Ports und DNS-Einträge, jeweils mit einer Behebung.
- Im Zertifikatsmenü stehen Status, ein Testlauf (Dry-Run, ohne Hooks), das Erneuern sowie eine erzwungene Neuausstellung mit Warnung bereit.
- Cloudflare-Proxy kann für das Panel eingeschaltet bleiben: Mit einem API-Token stellt das Setup das Zertifikat über die DNS-Prüfung aus. Das Token wird vorher geprüft und nur lokal gespeichert. Wings braucht dann eine eigene Subdomain ohne Proxy.
- Die Kurzbefehle `gmd`, `gd` (sofern der Name frei ist) und `germandactyl` nehmen Unterbefehle: `analyse` (auch `analyse --text --fix`), `backup`, `update` (`panel`, `wings` oder `system`), `ssl`, `wings`, `firewall`, `logs`, `status` und `hilfe`.
- Nach der Installation zeigt das Setup eine Übersicht "So geht es weiter" mit den wichtigsten Befehlen; `gmd hilfe` gibt sie jederzeit als Text aus.
- Im Express-Modus gibst du nur deine Domain ein; alles Weitere (anonymes Zertifikat, Benutzer admin, Firewall, fail2ban, Sicherheitsupdates, tägliche Backups) wird mit Standardwerten eingerichtet.
- Die E-Mail-Adresse für das Zertifikat ist jetzt optional. Bleibt sie leer, wird das Zertifikat anonym ausgestellt, und das Administrator-Konto erhält die Adresse admin@deine-domain; dann schickt Let's Encrypt keine Ablauf-Erinnerungen. Der Dialog erklärt beides.
- Vor der Installation prüft das Setup die IPv4-Verbindung, die Systemzeit, den freien Speicherplatz und warnt, wenn du über SSH ohne tmux oder screen installierst.
- Eine abgebrochene Installation lässt sich fortsetzen: Ist das Panel schon fertig und Wings fehlt noch, führt das Setup die Installation beim nächsten Start mit den gespeicherten Optionen weiter. Bricht die Installation mitten im Panel ab, bietet das Setup einen Neustart an; bereits installierte Pakete bleiben dabei erhalten.
- Der Anmeldehinweis (MOTD) zeigt das letzte Backup, das letzte automatische Update und hängende Backups mit dem kürzesten Befehl zur Behebung.
- Der Database-Host wird nach der Einrichtung automatisch im Panel angelegt, wenn das Panel auf diesem Server läuft. Schlägt das fehl, bleibt die manuelle Einrichtung mit allen Daten im Dialog.
- Der Kurzbefehl startet sofort aus einer lokalen Kopie des Setups; Updates werden im Hintergrund geprüft, statt bei jedem Aufruf von GitHub zu laden.
- Die Verwaltung kann optional direkt nach dem SSH-Login starten (Menü „Server & Sicherheit“).
- Die Admin-Zugangsdaten, das Backup-Passwort und die Daten des Database-Hosts kannst du als Textdatei über einen Link herunterladen. Der Link ist 90 Sekunden gültig, danach wird die Datei gelöscht.
- Die Firewall des Database-Hosts wird mit den Nodes abgeglichen: Die Analyse meldet fehlende Freigaben und behebt sie auf Wunsch, die Verwaltung gleicht sie beim Start ab, und ein nächtlicher Timer (04:30 Uhr) hält sie aktuell. Neue Nodes bekommen so automatisch Zugang zur Datenbank.
- Die Vorbereitung vor der Installation zeigt eine Ladeanimation und eine Schrittliste: Paketstatus, Paketquellen und Grundpakete werden einzeln als erledigt markiert.
- `gmd support` erstellt zusätzlich zum Archiv eine Textdatei für Support-Anfragen. Du kannst sie nach einer Vorschau und einer zweiten Bestätigung zu mclo.gs hochladen und den Link im Support-Kanal des GermanDactyl-Discords teilen.

### Sicherheit

- Passwörter und Tokens werden nicht mehr als Befehlsargumente übergeben und sind damit nicht in der Prozessliste für andere Benutzer sichtbar; Zugangsdaten zeigt das Setup in Dialogen, die nur root lesen kann.
- Dateien mit Zugangsdaten sind nur für root bzw. den Dienst lesbar (u. a. Panel- und Pelican-`.env`, Swap-Dateien, Backup-Konfiguration und das Cloudflare-Token).
- Die Firewall setzt die Standardregel "eingehenden Verkehr sperren" und lässt SSH nur mit Verbindungsbegrenzung zu. Die SSH-Ports liest das Setup aus der tatsächlichen Konfiguration aus, auch bei ssh.socket unter Ubuntu.
- Gameserver-Ports öffnet Docker direkt an der Firewall vorbei; das Setup weist in den Firewall-Dialogen darauf hin.
- MariaDB: Root-Konten für fremde Rechner werden entfernt. Der Datenbank-Server öffnet Port 3306 standardmäßig nur für das Panel und das Docker-Netz der Gameserver, nicht für das Internet.
- Das phpMyAdmin-Paket wird nur installiert, wenn seine Prüfsumme stimmt; der Download kommt ausschließlich von files.phpmyadmin.net.
- Die deutsche Übersetzung (Patch) wird nur angewendet, wenn ihre Prüfsumme mit der Liste im GermanDactyl-Repository übereinstimmt.
- Der Cronjob des Panels läuft als Benutzer www-data und nicht mehr als root.
- Das Support-Paket entfernt jetzt auch E-Mail-Adressen, lange Hex-Werte (Tokens und Hashes), Cloudflare-Tokens, Zugangsdaten von restic und S3 sowie Passwörter in URLs. Die Zeilen bleiben erhalten, nur die geheimen Werte werden ersetzt.

### Verbesserungen und Texte

- Der Fortschrittsbalken läuft auch bei langen Schritten (Build, Composer, Download) sichtbar weiter, statt minutenlang stehen zu bleiben.
- Texte im Fortschrittsbalken werden umgebrochen und mittig ausgerichtet.
- Dialoge passen ihre Höhe automatisch an, Menüs zeigen alle Einträge direkt, und Texte lassen sich auch auf kleinen Terminals scrollen.
- Downloads (Composer, Blueprint, Pelican, Wings, Patches) werden bei vorübergehenden Netzfehlern automatisch wiederholt.
- Vorhandene gültige Zertifikate werden nicht mehr unnötig neu ausgestellt, damit das Let's-Encrypt-Limit geschont wird.
- Bei der Wings-Installation prüft das Setup, ob Wings von außen erreichbar ist, und warnt bei einer Firewall des Hosters.
- Der Wings-Node wird mit Arbeitsspeicher und Festplatte angelegt, abzüglich einer Reserve: Liegt das Panel auf demselben Server, bleiben 1 GB RAM für Panel und Datenbank frei, und 10 % des freien Speichers bleiben als Puffer.
- Für den Build wird bei wenig Arbeitsspeicher automatisch und ohne Rückfrage eine temporäre Swap-Datei angelegt.
- Ein fehlgeschlagener Schritt bei der Backup-Einrichtung im Installer bricht die Installation nicht mehr ab.
- Das Hauptmenü zeigt die Ergebnisse der letzten Updates; die Analyse meldet fehlgeschlagene Dienste und Zertifikate, die in weniger als 24 Stunden ablaufen.
- Ein Backup, das länger als 6 Stunden als "läuft" steht, gilt als abgebrochen.
- Das Startmenü erkennt Pelican- und Pelican-Wings-Server direkt.
- Die Texte sind vereinheitlicht (Singular und Plural, Verweise auf Menüpunkte).

### Für Entwickler (CI, Tests, Skripte)

- Die CI prüft bei jedem Pull Request und jedem Push auf main die Syntax aller Skripte, führt shellcheck aus (Fehler brechen den Lauf ab, Warnungen erscheinen nur im Bericht) und startet die 279 Unit-Tests.
- Die Tests laufen mit `bash tests/run.sh` ohne root, ohne Netzzugriff und ohne whiptail.
- Der Installer hat einen Headless-Modus (`installer.sh --auto-update`) für geplante Läufe: keine Dialoge, Meldungen nur ins Log, Rückfragen gelten als Nein.
- Die Signatur der Prüfsummenliste und das Signierskript sind entfernt; Prüfsummen werden nur noch über die Liste abgeglichen.
- Ein einheitlicher Download-Helfer mit Wiederholungen ersetzt die verstreuten Aufrufe.
- Die Wings-Datei wird auf die angeforderte Version geprüft, bevor sie verwendet wird.
- Ein leeres Platzhalter-Skript (installAddon.sh) wurde entfernt.

### Hinweise zum Einsatz

- Debian 11 wird nicht mehr unterstützt, weil es keine Sicherheitsupdates mehr erhält. Getestet sind Debian 12 und 13 sowie Ubuntu 22.04, 24.04 und 26.04; neuere Versionen laufen mit einem Hinweis, dass sie nicht getestet sind.
- Alle Änderungen wurden mit Syntaxprüfung, shellcheck und Unit-Tests (279) geprüft. Die Installation "Panel + Wings" wurde auf einem Testserver (Debian) erfolgreich durchgeführt, das Backup lief.
- Mit installiertem Blueprint bleiben einige Oberflächendateien englisch. Der zweite Versuch mit Unschärfe ist eingebaut, das Ergebnis ist aber noch nicht auf dem Testserver bestätigt.
- Geplante Updates, die SFTP- und S3-Ziele, Cloudflare DNS-01 und die Wiederherstellung sind bisher nur in Sandbox-Tests geprüft.
- Das Projekt befindet sich in der Testphase. Setze es zuerst auf einem Testserver ein und erstelle vor Updates und Änderungen immer ein Backup.
- Bei Problemen hilft der Blick in die Logs unter `/var/log/germandactyl-setup/`; abgelehnte Übersetzungsteile liegen unter `/var/backups/germandactyl/`.
