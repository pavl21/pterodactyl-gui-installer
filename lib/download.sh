#!/bin/bash
# Pfad: lib/download.sh
# Zugangsdaten als zeitlich begrenzte Textdatei zum Herunterladen bereitstellen, statt sie aus der Konsole
# abzuschreiben. Die Datei liegt in GD_DL_DIR und ist über https://<panel-domain>/download/<token>.txt erreichbar
# (nginx-Snippet, siehe gd_download_nginx_snippet). Der Dateiname ist ein 32-stelliges Zufallstoken: Nur wer den
# Link kennt, findet die Datei. Benötigt lib/common.sh.

GD_DL_DIR="${GD_DL_DIR:-/var/lib/germandactyl/download}"
GD_DL_SNIPPET="${GD_DL_SNIPPET:-/etc/nginx/snippets/germandactyl-download.conf}"
GD_DL_PANEL_CONF="${GD_DL_PANEL_CONF:-/etc/nginx/sites-available/pterodactyl.conf}"

# Übriggebliebene Dateien entfernen (z. B. nach einem Abbruch des Skripts): alles, was älter als 5 Minuten ist
[ -d "$GD_DL_DIR" ] && find "$GD_DL_DIR" -mindepth 1 -maxdepth 1 -type f -mmin +5 -delete 2>/dev/null

gd_download_nginx_snippet() {
    # Legt das Verzeichnis und das nginx-Snippet an (idempotent: ein erneuter Aufruf schreibt denselben Inhalt).
    # Verzeichnis 711: nginx (www-data) darf die Dateien lesen, niemand kann den Inhalt des Verzeichnisses auflisten.
    mkdir -p "$GD_DL_DIR" && chmod 711 "$GD_DL_DIR" || return 1
    mkdir -p "$(dirname "$GD_DL_SNIPPET")" || return 1
    cat > "$GD_DL_SNIPPET" <<EOF
# Angelegt von GermanDactyl Setup: einmalige Zugangsdaten-Downloads (lib/download.sh)
location ^~ /download/ {
    alias ${GD_DL_DIR}/;
    # Kein Zugriffslog: Der Dateiname ist der Schlüssel zur Datei und darf nicht in einem Log landen
    access_log off;
    autoindex off;
    add_header Cache-Control "no-store";
    add_header X-Content-Type-Options nosniff;
    default_type text/plain;
    types { }
    try_files \$uri =404;
}
EOF
}

gd_download_nginx_ensure() {
    # Bindet das Snippet in die Panel-Site ein (bestehende Installationen; neue bekommen die Zeile in
    # gd_nginx_ssl_config). Die Einbindung steht im 443-Block vor "location / {". Schlägt nginx -t oder der
    # Reload fehl, wird die Konfiguration aus der Sicherung zurückgespielt.
    # Rückgabe 0 = eingebunden (oder schon vorhanden), 1 = nicht möglich, Einbindung zurückgenommen
    local conf="$GD_DL_PANEL_CONF" inc="    include snippets/germandactyl-download.conf;" bak
    [ -f "$conf" ] || return 1
    gd_download_nginx_snippet || return 1
    grep -q "germandactyl-download.conf" "$conf" && return 0

    bak="$(mktemp "${GD_TMP:-/tmp}/download-conf.XXXXXX")" || return 1
    cp -p "$conf" "$bak" || { rm -f "$bak"; return 1; }
    if ! awk -v inc="$inc" '
        /listen[^;]*443/ { in443 = 1 }
        in443 && !done && /^    location \/ \{/ { print inc; done = 1 }
        { print }
        END { exit !done }' "$bak" > "$bak.new"; then
        gd_log "Download: location-Block im 443-Bereich der Panel-Site nicht gefunden"
        rm -f "$bak" "$bak.new" "$GD_DL_SNIPPET"
        return 1
    fi
    cat "$bak.new" > "$conf" || { cp -p "$bak" "$conf"; rm -f "$bak" "$bak.new"; return 1; }

    if nginx -t >> "$GD_LOG" 2>&1 && systemctl reload nginx >> "$GD_LOG" 2>&1; then
        rm -f "$bak" "$bak.new"
        return 0
    fi
    # Fehler: Einbindung zurücknehmen, damit nginx (und das Panel) weiterlaufen
    gd_log "Download: nginx-Konfiguration mit dem Download-Snippet ist fehlerhaft, wird zurückgenommen"
    cp -p "$bak" "$conf"
    rm -f "$GD_DL_SNIPPET" "$bak" "$bak.new"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
    return 1
}

gd_download_offer() {
    # gd_download_offer "Titel" "Dateiinhalt" [sekunden=90]
    # Fragt, ob die Zugangsdaten als Datei heruntergeladen werden sollen. Bei Ja wird die Datei bereitgestellt und der
    # Link angezeigt. Nach dem Schließen des Dialogs wird die Datei gelöscht. Eine Hintergrundaufgabe löscht sie
    # außerdem nach <sekunden>, falls der Dialog länger offen bleibt oder das Skript abbricht.
    # Der Dateiinhalt ist ein Text wie bei gd_msg (\n wird umgebrochen). Rückgabe 0 = angeboten oder nicht gewünscht,
    # 1 = Download nicht möglich (Meldung wurde angezeigt).
    local title="$1" content="$2" sek="${3:-90}" domain token file link stamp bg
    gd_yesno "Zugangsdaten als Datei herunterladen?" "Zugangsdaten als Datei herunterladen? Der Link ist ${sek} Sekunden gültig. Danach wird die Datei gelöscht." 10 70 || return 0

    domain="$(gd_conf_get PANEL_DOMAIN)"
    if [ -z "$domain" ] || ! systemctl is-active --quiet nginx; then
        gd_msg "Download nicht möglich" "Download nicht möglich, Panel/nginx läuft nicht.\n\nSpeichere die Zugangsdaten jetzt von Hand ab." 10 70
        return 1
    fi
    if ! gd_download_nginx_ensure; then
        gd_msg "Download nicht möglich" "Der Webserver konnte nicht für den Download eingerichtet werden (Details im Log: $GD_LOG).\n\nSpeichere die Zugangsdaten jetzt von Hand ab." 11 74
        return 1
    fi

    token="$(gd_gen_password 32)"
    file="$GD_DL_DIR/$token.txt"
    stamp="$(date '+%d.%m.%Y %H:%M')"
    # umask 022: Die Datei ist 644, nginx kann sie lesen (das Verzeichnis ist 711 und nicht auflistbar)
    if ! ( umask 022; printf 'GermanDactyl Setup – Zugangsdaten vom %s\n%s\n\n%b\n\nDiese Datei wurde nur %s Sekunden bereitgestellt. Bewahre sie sicher auf (z. B. Passwort-Manager) und lösche sie danach vom Download-Ort.\n' \
        "$stamp" "$title" "$content" "$sek" > "$file" ); then
        rm -f "$file"
        gd_msg "Download nicht möglich" "Die Datei konnte nicht geschrieben werden (Details im Log: $GD_LOG).\n\nSpeichere die Zugangsdaten jetzt von Hand ab." 10 70
        return 1
    fi

    # Sicherheitsnetz: Die Datei verschwindet spätestens nach <sekunden>, auch wenn der Dialog offen bleibt
    # oder das Skript abbricht. Der Prozess läuft losgelöst weiter (disown).
    ( sleep "$sek"; rm -f "$file" ) >/dev/null 2>&1 &
    bg=$!
    disown "$bg" 2>/dev/null

    link="https://${domain}/download/${token}.txt"
    gd_log "Zugangsdaten-Download bereitgestellt: $title (${sek} Sekunden)"
    gd_msg_secret "✱ Download-Link: $title" "Öffne diesen Link in einem Browser und speichere die Datei. Sie ist nur ${sek} Sekunden verfügbar und wird danach gelöscht:\n\n${link}\n\nSchließe dieses Fenster erst, wenn die Datei gespeichert ist." 14 78
    # Der Dialog ist geschlossen: Die Datei wird sofort gelöscht
    rm -f "$file"
    return 0
}

gd_download_cleanup_all() {
    # Alle bereitgestellten Dateien entfernen (z. B. bei der Deinstallation). Das Verzeichnis bleibt bestehen.
    [ -d "$GD_DL_DIR" ] && find "$GD_DL_DIR" -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null
    return 0
}
