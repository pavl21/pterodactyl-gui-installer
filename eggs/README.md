# Pterodactyl Eggs für GermanDactyl

Dieses Verzeichnis enthält eine Sammlung von Custom Pterodactyl Eggs, die speziell für die deutsche Community entwickelt wurden.

## Was sind Pterodactyl Eggs?

Pterodactyl Eggs sind JSON-Konfigurationsdateien, die definieren, wie Anwendungen und Game-Server im Pterodactyl Panel installiert und ausgeführt werden. Sie enthalten:

- Docker-Image-Spezifikationen
- Installations-Scripts
- Startup-Befehle
- Konfigurierbare Umgebungsvariablen
- Port-Mappings und weitere Einstellungen

## Verfügbare Eggs

### 📋 Productivity

#### Planka
Ein elegantes, Open-Source-Projektmanagement-Tool für Workgroups. Verwalten Sie Ihre Projekte mit Kanban-Boards - komplett selbst gehostet.

- **Verzeichnis**: `eggs/planka/`
- **Dokumentation**: [README](planka/README.md)
- **Egg-Datei**: [egg-planka.json](planka/egg-planka.json)
- **Features**: Kanban-Boards, Echtzeit-Kollaboration, OIDC-Support, SMTP-Integration
- **Anforderungen**: PostgreSQL-Datenbank

## Installation

### Egg in Pterodactyl importieren

1. Gehen Sie zu **Admin** → **Nests** im Pterodactyl Panel
2. Erstellen Sie ein neues Nest oder wählen Sie ein bestehendes aus
3. Klicken Sie auf **Import Egg**
4. Wählen Sie die gewünschte `egg-*.json` Datei aus dem entsprechenden Verzeichnis
5. Konfigurieren Sie die Egg-Einstellungen nach Bedarf

### Server erstellen

1. Gehen Sie zu **Servers** → **Create New Server**
2. Wählen Sie das importierte Egg aus
3. Konfigurieren Sie die Serverressourcen (RAM, CPU, Disk)
4. Setzen Sie die erforderlichen Umgebungsvariablen
5. Erstellen Sie den Server und starten Sie ihn

## Beitragen

Haben Sie ein eigenes Egg erstellt, das Sie mit der Community teilen möchten?

1. Forken Sie dieses Repository
2. Erstellen Sie einen neuen Ordner in `eggs/` mit dem Namen Ihrer Anwendung
3. Fügen Sie Ihre `egg-*.json` und eine `README.md` hinzu
4. Erstellen Sie einen Pull Request

### Egg-Struktur

```
eggs/
└── ihre-anwendung/
    ├── egg-ihre-anwendung.json    # Das Egg selbst
    ├── README.md                  # Dokumentation
    └── screenshots/               # Optional: Screenshots
        └── *.png
```

### README-Vorlage

Ihre `README.md` sollte mindestens enthalten:

- Beschreibung der Anwendung
- Voraussetzungen (z.B. Datenbanken, externe Services)
- Installations-Anleitung
- Konfigurationshinweise
- Fehlerbehebung
- Links zur offiziellen Dokumentation

## Ressourcen

### Offizielle Pterodactyl Eggs

- **Pelican Eggs**: https://github.com/pelican-eggs
- **Games (SteamCMD)**: https://github.com/pelican-eggs/games-steamcmd
- **Games (Standalone)**: https://github.com/pelican-eggs/games-standalone
- **Minecraft**: https://github.com/pelican-eggs/minecraft
- **Generic**: https://github.com/pelican-eggs/generic

### Dokumentation

- **Pterodactyl Docs**: https://pterodactyl.io/
- **Pelican Panel**: https://pelican.dev/
- **Egg Development**: https://pterodactyl.io/community/config/eggs/creating_a_custom_egg.html

## Support

Bei Fragen oder Problemen:

1. Lesen Sie die README des jeweiligen Eggs
2. Überprüfen Sie die offizielle Dokumentation der Anwendung
3. Öffnen Sie ein Issue in diesem Repository
4. Besuchen Sie die GermanDactyl Community

## Lizenz

Alle Eggs in diesem Repository sind unter der **MIT License** verfügbar, sofern nicht anders angegeben.

Die enthaltenen Anwendungen selbst unterliegen ihren jeweiligen Lizenzen.

---

**Made with ❤️ for the GermanDactyl Community**

🇩🇪 Proudly German
