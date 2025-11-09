# 🚀 Pterodactyl TUI Installer für GermanDactyl

<div align="center">

**Automatisierter Installer für Pterodactyl Panel & Wings mit deutscher Lokalisierung**

[![Status](https://img.shields.io/badge/Status-Beta-yellow)](https://github.com/pavl21/pterodactyl-gui-installer)
[![Pterodactyl](https://img.shields.io/badge/Pterodactyl-v1.11-blue)](https://pterodactyl.io)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

[Installation](#-installation) • [Features](#-features) • [GDS Commands](#-gds-management-commands) • [Support](#-support)

</div>

---

## 📋 Über das Projekt

Dieser Installer ermöglicht die **vollautomatische Installation** von Pterodactyl Panel und Wings in nur wenigen Schritten. Das Projekt ist Teil von **GermanDactyl** und bietet eine benutzerfreundliche TUI (Terminal User Interface) für die Installation und Verwaltung.

> **Hinweis:** Ja, es ist ein TUI, keine GUI. Ich weiß. 😄

Die Basis des Installationsscripts stammt von [Vilhelm Prytz](https://github.com/vilhelmprytz) und wurde für die deutsche Community erweitert und optimiert.

---

## ✨ Features

### Installation
- ✅ **Vollautomatische Panel-Installation** mit SSL-Zertifikat
- ✅ **Standalone Wings-Installation** (config-first Ansatz)
- ✅ **Blueprint-Integration** mit korrekter Installationsreihenfolge
- ✅ **GermanDactyl-Plugin** automatische Installation
- ✅ **Database Host Management** mit sicherer Passwortanzeige
- ✅ **Backup-Verwaltung** für Panel und Server
- ✅ **Automatische SSL-Zertifikat-Erneuerung** via Certbot

### Verwaltung
- 🔧 **GDS Management Commands** - Praktische CLI-Tools zur Verwaltung
- 💾 **Backup-System** mit automatischer Rotation
- 🔐 **SSL-Verwaltung** mit Status-Anzeige
- 🛠️ **Wartungsmodus** einfach aktivieren/deaktivieren
- 👥 **Benutzerverwaltung** mit interaktiven Dialogs

### Sicherheit
- 🔒 256-stellige Passwörter für Database Hosts
- 🔐 SSL-Zertifikate via Let's Encrypt
- ✅ Sichere Passwortbestätigung (Eingabe "Gespeichert" erforderlich)
- 🛡️ Automatische Firewall-Konfiguration

---

## 🚀 Installation

### Voraussetzungen
- Debian 11/12 oder Ubuntu 20.04/22.04
- Root-Zugriff
- Gültige Domain mit DNS-Eintrag
- Mindestens 2 GB RAM

### Schnellstart

Starte den Installer mit einem einzigen Befehl:

```bash
sudo bash -c "$(curl -sSL https://setup.germandactyl.de/)"
```

Der Installer führt dich durch alle notwendigen Schritte:
1. **Installationstyp wählen** (Panel, Wings, Panel + Wings)
2. **Domain und E-Mail angeben**
3. **Passwort festlegen**
4. **Installation läuft automatisch**
5. **Fertig!**

---

## 🎯 GDS Management Commands

Nach der Installation stehen dir praktische Verwaltungsbefehle zur Verfügung:

### Hauptbefehle

| Befehl | Beschreibung |
|--------|-------------|
| `gds setup` | Wartungs- und Verwaltungsmenü öffnen |
| `gds maintenance` | Wartungsmodus aktivieren/deaktivieren |
| `gds backup` | Backup-Verwaltung öffnen |
| `gds domain` | Panel-Domain anzeigen |
| `gds cert` | SSL-Zertifikat-Status anzeigen |

### Zusätzliche Befehle

| Befehl | Beschreibung |
|--------|-------------|
| `gds update` | Pterodactyl Panel aktualisieren |
| `gds cache` | Cache leeren (config, view, route) |
| `gds restart` | Alle Pterodactyl-Dienste neu starten |
| `gds status` | Status aller Dienste anzeigen |
| `gds logs` | Letzte Panel-Logs anzeigen |
| `gds info` | Panel-Informationen anzeigen |
| `gds user` | Neuen Benutzer erstellen |
| `gds help` | Hilfe anzeigen |

### Beispiele

```bash
# Wartungsmodus aktivieren
gds maintenance

# Backup erstellen
gds backup

# SSL-Zertifikat-Status prüfen
gds cert

# Panel aktualisieren
gds update

# Neuen Admin-Benutzer erstellen
gds user
```

---

## 🛠️ Voreinstellungen

Um die Installation so einfach wie möglich zu gestalten, werden folgende Voreinstellungen vorgenommen:

- **UFW-Firewall:** Wird nicht automatisch aktiviert (verhindert Installationsprobleme)
- **Panel-Datenbank:** Wird automatisch erstellt, Zugangsdaten werden intern verwaltet
- **Composer-Telemetrie:** Standardmäßig aktiviert (enthält keine persönlichen Daten)
- **Redis:** Als Cache- und Session-Driver konfiguriert
- **Queue Worker:** Automatisch als systemd-Service eingerichtet

---

## 🧪 Testing & Entwicklung

Dieses Projekt konnte dank der **leistungsstarken Server von 24fire** ausgiebig getestet werden. Trotz intensiver Tests können jederzeit neue Fehler auftreten - das Projekt befindet sich noch in der **Beta-Phase**.

### 24fire Hosting

Möchtest du das Projekt selbst testen oder als Hosting-Anbieter verwenden?

🎁 **Erhalte 10% Cashback bei deiner ersten Bestellung:**

**➡️ https://24fi.re/ref/pavl**

24fire bietet:
- ⚡ Hochperformante Server
- 🇩🇪 Deutscher Support
- 💰 Faire Preise
- 🔒 DDoS-Schutz
- 📊 Pterodactyl-optimiert

---

## 📦 Backup-Verwaltung

Die integrierte Backup-Verwaltung bietet:

- **Panel-Backups:** Komplette Panel-Sicherung inkl. Datenbank
- **Server-Backups:** Alle Gameserver-Daten
- **Automatische Rotation:** Alte Backups werden automatisch gelöscht
- **Fortschrittsanzeige:** Live-Progress beim Erstellen/Wiederherstellen
- **Komprimierung:** Platzsparende .tar.gz Archive

Backups werden standardmäßig in `/opt/pterodactyl/backups/` gespeichert.

```bash
# Backup-Verwaltung öffnen
gds backup
```

---

## 🔐 Database Host Management

Erstelle sichere MySQL Database Hosts direkt aus dem Installer:

- 🔑 256-stellige zufällige Passwörter
- 🌐 Öffentlich erreichbar (mit starker Authentifizierung)
- ✅ Sichere Passwortanzeige mit Bestätigung
- 🗑️ Automatisches Rollback bei Fehlern

Starte das Tool mit:
```bash
# Aus dem Hauptmenü oder direkt
bash database-host-config.sh
```

---

## 🆘 Support

### Fehler gefunden?

Bitte melde Fehler über die [GitHub Issues](https://github.com/pavl21/pterodactyl-gui-installer/issues).

### Hilfe benötigt?

- 📚 [Pterodactyl Dokumentation](https://pterodactyl.io/panel/1.0/getting_started.html)
- 💬 [GermanDactyl Community](https://germandactyl.de)
- 🎮 24fire Support (bei Hosting-Fragen)

---

## 💝 Projekt unterstützen

Wenn dir dieses Projekt weitergeholfen hat, würde ich mich über eine Spende freuen!

**🔗 Spenden-Link:** https://spenden.24fire.de/pavl

Deine Unterstützung hilft bei:
- ⚙️ Weiterentwicklung des Projekts
- 🐛 Bug-Fixes und Verbesserungen
- 📖 Dokumentation und Tutorials
- 🧪 Testing auf verschiedenen Systemen

---

## 📜 Lizenz & Credits

### Lizenz
Dieses Projekt steht unter der [MIT License](LICENSE).

### Credits & Danksagungen

- **[Vilhelm Prytz](https://github.com/vilhelmprytz)** - Basis-Installationsscript
- **[Pterodactyl Panel](https://pterodactyl.io)** - Das beste Game-Server-Management-Panel
- **[24fire](https://24fi.re/ref/pavl)** - Testing-Server und Hosting-Partner
- **GermanDactyl Community** - Feedback und Testing

### Entwicklung
- **Hauptentwickler:** Pavl21
- **AI-Assistenz:** Claude (Anthropic)
- **Version:** Beta 1.0

---

## ⚠️ Haftungsausschluss

Dieses Projekt ist **inoffiziell** und wird nicht vom Pterodactyl-Team unterstützt. Die Verwendung erfolgt **auf eigene Verantwortung**. Der Entwickler haftet nicht für:

- Datenverlust
- Systemausfälle
- Sicherheitsprobleme
- Sonstige Schäden

**Empfehlung:** Teste den Installer zuerst in einer sicheren Umgebung (z.B. VM) bevor du ihn produktiv einsetzt.

---

## 🔄 Updates & Roadmap

### Geplante Features
- [ ] Automatische Panel-Updates via Cronjob
- [ ] Mehrsprachigkeit (EN/DE)
- [ ] Docker-Installation optimieren
- [ ] Backup-Verschlüsselung
- [ ] Monitoring-Integration
- [ ] Ansible-Playbooks

### Letzte Updates
- ✅ GDS Management Commands (v1.0)
- ✅ Standalone Wings Installation
- ✅ Blueprint/GermanDactyl Integration
- ✅ Sichere Passwortbestätigung
- ✅ Spenden-Integration

---

## 🌟 Mehr Features gewünscht?

**Du möchtest dich nicht selbst um das Panel kümmern und noch mehr Features haben?**

Dann könnte mein eigenes Projekt **PVQ-Panel** für dich interessant sein:

<div align="center">

### 🎮 PVQ-Panel

**Professionelle Game-Server-Verwaltung mit erweiterten Features**

✨ **Kostenlos nutzbar** • 💝 **Spendenfinanziert**

[**➡️ Mehr erfahren auf pavl21.de**](https://pavl21.de)

</div>

Das PVQ-Panel bietet dir:
- 🎯 **Mehr Features** als Standard-Pterodactyl
- 🛠️ **Fertig konfiguriert** - keine aufwendige Wartung
- 🔄 **Automatische Updates** und Patches
- 💡 **Erweiterte Verwaltungsfunktionen**
- 🎨 **Optimierte Benutzeroberfläche**
- 🆓 **Komplett kostenlos** - finanziert durch Spenden

Wenn du lieber eine **schlüsselfertige Lösung** haben möchtest, statt das Panel selbst zu hosten und zu verwalten, ist PVQ-Panel die perfekte Alternative!

---

<div align="center">

**Made with ❤️ for the German Pterodactyl Community**

[⬆ Nach oben](#-pterodactyl-tui-installer-für-germandactyl)

</div>
