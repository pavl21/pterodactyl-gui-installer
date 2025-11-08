# Planka Pterodactyl Egg

![Planka Logo](https://planka.app/assets/planka-logo.png)

Ein Pterodactyl/Pelican Panel Egg für [Planka](https://planka.app/) - ein elegantes, Open-Source-Projektmanagement-Tool für Workgroups.

## Über Planka

Planka ist eine selbst gehostete, kollaborative Kanban-Board-Lösung, ähnlich wie Trello. Es bietet:

- 📋 Kanban-Boards mit Drag & Drop
- 🔄 Echtzeit-Updates für Teams
- 📝 Markdown-Editor für Card-Beschreibungen
- 🔔 Flexible Benachrichtigungen (100+ Provider)
- 🔐 OpenID Connect (OIDC) Single Sign-On
- 🌍 Mehrsprachige Unterstützung
- 📎 Dateianhänge und Kommentare
- 👥 Benutzer- und Rollenverwaltung

## Voraussetzungen

### PostgreSQL-Datenbank (ERFORDERLICH)

Planka benötigt zwingend eine PostgreSQL-Datenbank. Sie haben folgende Optionen:

#### Option 1: Externe PostgreSQL-Datenbank
Verwenden Sie einen externen PostgreSQL-Server oder Hosting-Service.

#### Option 2: PostgreSQL als Pterodactyl-Service
Erstellen Sie einen separaten PostgreSQL-Container in Ihrem Pterodactyl Panel:
1. Installieren Sie ein PostgreSQL Egg
2. Erstellen Sie eine Datenbank namens `planka`
3. Notieren Sie sich Host, Port, Benutzername und Passwort

#### Option 3: Database Host im Panel
Wenn Ihr Panel einen Database Host konfiguriert hat, können Sie direkt eine Datenbank erstellen.

### Beispiel DATABASE_URL

```
postgresql://benutzername:passwort@datenbank-host:5432/planka
```

Ersetzen Sie:
- `benutzername`: Ihr PostgreSQL-Benutzername
- `passwort`: Ihr PostgreSQL-Passwort
- `datenbank-host`: IP-Adresse oder Hostname des PostgreSQL-Servers
- `5432`: PostgreSQL-Port (Standard: 5432)
- `planka`: Name der Datenbank

## Installation

### 1. Egg importieren

1. Laden Sie die `egg-planka.json` Datei herunter
2. Gehen Sie in Ihrem Pterodactyl Panel zu **Admin** → **Nests** → **Create New**
3. Erstellen Sie ein neues Nest namens "Productivity" oder verwenden Sie ein bestehendes
4. Klicken Sie auf **Import Egg**
5. Wählen Sie die `egg-planka.json` Datei aus

### 2. Server erstellen

1. Erstellen Sie einen neuen Server mit dem Planka Egg
2. Empfohlene Ressourcen:
   - **RAM**: Mindestens 512MB, empfohlen 1GB
   - **CPU**: Mindestens 50%, empfohlen 100%
   - **Disk Space**: Mindestens 2GB (abhängig von Uploads)

### 3. Konfiguration

#### Pflichtfelder:

1. **Base URL**: Die vollständige URL, unter der Planka erreichbar ist
   ```
   https://planka.example.com
   ```
   oder für lokale Tests:
   ```
   http://ihre-server-ip:3000
   ```

2. **Database URL**: PostgreSQL-Verbindungsstring (siehe oben)

3. **Secret Key**: Generieren Sie einen sicheren Schlüssel:
   ```bash
   openssl rand -hex 64
   ```
   Dieser Schlüssel wird für Session-Verschlüsselung verwendet. **NIEMALS teilen oder wiederverwenden!**

#### Optionale Felder:

- **Default Language**: Standard-Sprache (de-DE für Deutsch)
- **Trust Proxy**: Auf `true` setzen, wenn Sie einen Reverse Proxy verwenden
- **Max Upload File Size**: Maximale Dateigröße in Bytes (Standard: 10MB)
- **Token Expires In**: Gültigkeitsdauer von Sessions in Tagen

#### E-Mail-Benachrichtigungen (Optional):

Für E-Mail-Benachrichtigungen konfigurieren Sie:
- **SMTP Host**: Ihr SMTP-Server
- **SMTP Port**: 587 (STARTTLS) oder 465 (SSL)
- **SMTP User**: SMTP-Benutzername
- **SMTP Password**: SMTP-Passwort
- **SMTP From**: Absender-Adresse (z.B. "Planka" <noreply@example.com>)
- **SMTP Secure**: `true` für SSL (Port 465), `false` für STARTTLS (Port 587)

### 4. Server starten

1. Starten Sie den Server
2. Warten Sie, bis die Meldung "Server is listening on port" erscheint
3. Öffnen Sie die BASE_URL in Ihrem Browser

### 5. Admin-Benutzer erstellen

#### Methode 1: Über Umgebungsvariablen (Empfohlen für erste Einrichtung)

Setzen Sie folgende Variablen im Panel:
- **DEFAULT_ADMIN_EMAIL**: admin@example.com
- **DEFAULT_ADMIN_PASSWORD**: IhrSicheresPasswort
- **DEFAULT_ADMIN_NAME**: Admin Name
- **DEFAULT_ADMIN_USERNAME**: admin

**WICHTIG**: Entfernen Sie diese Variablen nach der ersten Anmeldung oder setzen Sie sie auf leer, sonst werden Änderungen in der UI überschrieben!

#### Methode 2: Über die Konsole

Falls Sie die Variablen nicht gesetzt haben, können Sie einen Admin über die Konsole erstellen:

1. Gehen Sie zur Server-Konsole im Panel
2. Führen Sie folgenden Befehl aus:
   ```bash
   npm run db:create-admin-user
   ```
3. Folgen Sie den Anweisungen in der Konsole

## Port-Konfiguration

Planka läuft intern auf Port **1337**. Pterodactyl mappt diesen automatisch auf die zugewiesene Allocation.

Für Reverse Proxy (z.B. Nginx, Caddy):
```nginx
location / {
    proxy_pass http://localhost:IHRE_ALLOCATION_PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host $host;
    proxy_cache_bypass $http_upgrade;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Setzen Sie dann `TRUST_PROXY=true` in den Umgebungsvariablen.

## Erweiterte Konfiguration

### OIDC/OAuth-Integration

Planka unterstützt OpenID Connect für Single Sign-On. Konfigurieren Sie dies über zusätzliche Umgebungsvariablen:

```
OIDC_ISSUER=https://auth.example.com
OIDC_CLIENT_ID=planka
OIDC_CLIENT_SECRET=ihr_client_secret
OIDC_SCOPES=openid email profile
```

Siehe [Planka Dokumentation](https://docs.planka.cloud/) für weitere Details.

### S3-Storage für Uploads

Für große Deployments können Sie Uploads auf S3-kompatiblen Storage auslagern:

```
S3_ENDPOINT=https://s3.amazonaws.com
S3_REGION=eu-central-1
S3_ACCESS_KEY_ID=ihr_access_key
S3_SECRET_ACCESS_KEY=ihr_secret_key
S3_BUCKET=planka-uploads
```

## Datenpersistenz

Planka speichert Daten in folgenden Verzeichnissen:
- `/app/public/favicons` - Board-Icons
- `/app/public/user-avatars` - Benutzer-Avatare
- `/app/public/background-images` - Hintergrundbilder
- `/app/private/attachments` - Dateianhänge

Diese werden automatisch vom Pterodactyl Panel persistiert.

## Backup

Um ein Backup zu erstellen, sichern Sie:
1. **PostgreSQL-Datenbank**: Verwenden Sie `pg_dump`
   ```bash
   pg_dump -h localhost -U postgres planka > planka_backup.sql
   ```
2. **Datei-Uploads**: Die oben genannten Verzeichnisse

## Wiederherstellung

1. Stellen Sie die PostgreSQL-Datenbank wieder her:
   ```bash
   psql -h localhost -U postgres planka < planka_backup.sql
   ```
2. Kopieren Sie die gesicherten Dateien zurück in die Verzeichnisse
3. Starten Sie Planka neu

## Fehlerbehebung

### "Database connection failed"
- Überprüfen Sie die DATABASE_URL
- Stellen Sie sicher, dass PostgreSQL läuft und erreichbar ist
- Prüfen Sie Firewall-Regeln zwischen Planka und PostgreSQL

### "Invalid secret key"
- Der SECRET_KEY muss mindestens 32 Zeichen lang sein
- Generieren Sie einen neuen mit `openssl rand -hex 64`

### "Cannot create admin user"
- Stellen Sie sicher, dass die Datenbank leer ist oder
- Verwenden Sie die DEFAULT_ADMIN_* Umgebungsvariablen

### Logs anzeigen
Im Pterodactyl Panel unter "Console" können Sie alle Planka-Logs in Echtzeit sehen.

## Updates

Um Planka zu aktualisieren:
1. Gehen Sie zu **Admin** → **Nests** → **Planka Egg**
2. Ändern Sie die Docker-Image-Version
3. Starten Sie den Server neu

Oder wählen Sie im Server die gewünschte Docker-Image-Version aus den verfügbaren Optionen:
- **Planka Latest**: Immer die neueste Version
- **Planka 2.0.0-rc.4**: Aktueller Release Candidate
- **Planka 1.21.2**: Stabile Legacy-Version

## Ressourcen

- **Offizielle Website**: https://planka.app/
- **GitHub Repository**: https://github.com/plankanban/planka
- **Dokumentation**: https://docs.planka.cloud/
- **Docker Hub**: https://hub.docker.com/r/meltyshev/planka
- **Community**: Discord (siehe GitHub)

## Support

Bei Problemen mit dem Egg:
- Öffnen Sie ein Issue im GermanDactyl Repository
- Für Planka-spezifische Fragen: https://github.com/plankanban/planka/issues

## Lizenz

- **Planka**: Fair Code License (Community Edition kostenlos)
- **Dieses Egg**: MIT License

## Credits

- **Planka Entwickler**: https://github.com/plankanban
- **Egg erstellt von**: GermanDactyl Team
- **Basierend auf**: Pterodactyl Egg System

---

**Made with ❤️ for the GermanDactyl Community**
