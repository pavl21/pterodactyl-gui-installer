# Pterodactyl TUI Installer (inoffiziell) für GermanDactyl - Beta
Zu allererst: Ja, es ist ein TUI keine GUI. Ich weiß.
Installiert das Pterodactyl Panel automatisch in 2 Schritten, die Basis des Installationscriptes stammt von [dem Entwickler namens Vilhelm Prytz](https://github.com/vilhelmprytz).
Dies ist ein Teil von GermanDactyl.

Es können noch Fehler auftreten.


# Hinweis
Das Script ist noch nicht vollständig einsatzbereit und noch in Entwicklung. Dies ist eine inoffizielle Methode und die Verwendung unterliegt auf eigene Verantwortung.

Starten kannst du es mit diesem Befehl: 
`sudo bash -c "$(curl -sSL https://setup.germandactyl.de/)"`


## Voreinstellungen
Damit so wenig Eingaben wie möglich notwenig sind, werden einige Angaben vordefiniert. 
- Die UFW-Firewall wird nicht aktiviert, somit kann das Panel und Wings problemlos installiert werden. Beim testen habe ich festgestellt, das die UFW Firewall gerne mal die Installation verhindert, das kann aber später eingereichtet werden.
- Die Datenbank für das Panel wird automatisch erstellt. Die Zugangsdaten werden vorenthalten, da sie nicht benötigt werden. Diese Datenbank darf NICHT für ein Database-Host verwendet werden.
- Mit dem Entwicklern der Composer Abhängigkeiten werden standardmaäßig die Telemetriedaten geteilt. Damit wird bei einem Fehler die Logs des Fehlers an die Entwickler weitergegeben, in den Logs sind keine persönlichen Daten enthalten.
