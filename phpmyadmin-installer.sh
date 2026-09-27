#!/bin/bash
# Pfad: phpmyadmin-installer.sh
# phpMyAdmin installieren. Es liegt außerhalb des Panel-Ordners (/usr/share/phpmyadmin),
# damit es bei Panel-Updates nicht gelöscht wird, und ist unter https://<panel-domain>/phpmyadmin erreichbar.

# Gemeinsame Bibliotheken laden (vom Hauptskript übergeben, lokal oder aus dem Repository)
_gd_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "${GD_LIB_DIR:-}" ] && [ -f "$_gd_dir/lib/common.sh" ]; then GD_LIB_DIR="$_gd_dir/lib"; GD_LOCAL_DIR="$_gd_dir"; fi
if [ -n "${GD_LIB_DIR:-}" ] && [ -f "$GD_LIB_DIR/common.sh" ]; then
    . "$GD_LIB_DIR/common.sh"
else
    _gd_c="$(mktemp)"
    curl -fsSL "https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/${GD_BRANCH:-main}/lib/common.sh" -o "$_gd_c" \
        || { echo "Die Bibliothek lib/common.sh konnte nicht geladen werden."; exit 1; }
    . "$_gd_c"; rm -f "$_gd_c"
fi
gd_require_root
gd_source_lib panel

PMA_DIR="/usr/share/phpmyadmin"
PMA_SNIPPET="/etc/nginx/snippets/germandactyl-phpmyadmin.conf"
PANEL_NGINX="/etc/nginx/sites-available/pterodactyl.conf"

install_phpmyadmin() {
    local line version url sock
    line="$(curl -fsSL https://www.phpmyadmin.net/home_page/version.txt)" || return 1
    version="$(sed -n '1p' <<< "$line")"
    url="$(sed -n '3p' <<< "$line")"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unbekanntes Versionsformat: $version"; return 1; }
    [ -z "$url" ] && url="https://files.phpmyadmin.net/phpMyAdmin/${version}/phpMyAdmin-${version}-all-languages.zip"
    echo "phpMyAdmin $version wird installiert: $url"

    gd_apt_install unzip || return 1
    curl -fsSL "$url" -o "$GD_TMP/pma.zip" || return 1
    # Prüfsumme kontrollieren, falls verfügbar
    if curl -fsSL "${url}.sha256" -o "$GD_TMP/pma.sha256" 2>/dev/null; then
        [ "$(awk '{print $1}' "$GD_TMP/pma.sha256")" = "$(sha256sum "$GD_TMP/pma.zip" | awk '{print $1}')" ] \
            || { echo "Prüfsumme stimmt nicht überein – Abbruch."; return 1; }
    fi
    unzip -q "$GD_TMP/pma.zip" -d "$GD_TMP/pma" || return 1
    rm -rf "$PMA_DIR"
    mv "$GD_TMP/pma/phpMyAdmin-${version}-all-languages" "$PMA_DIR" || return 1
    mkdir -p "$PMA_DIR/tmp"

    cat > "$PMA_DIR/config.inc.php" <<EOF
<?php
// Angelegt von GermanDactyl Setup
\$cfg['blowfish_secret'] = '$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)';
\$cfg['TempDir'] = '${PMA_DIR}/tmp';
\$cfg['DefaultLang'] = 'de';
\$i = 1;
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
EOF
    chown -R root:www-data "$PMA_DIR"
    chmod 640 "$PMA_DIR/config.inc.php"
    chown -R www-data:www-data "$PMA_DIR/tmp"
    chmod 750 "$PMA_DIR/tmp"

    # nginx: phpMyAdmin als Unterverzeichnis der Panel-Domain einbinden
    sock="$(gd_php_fpm_socket)"
    mkdir -p /etc/nginx/snippets
    cat > "$PMA_SNIPPET" <<EOF
# Angelegt von GermanDactyl Setup: phpMyAdmin unter /phpmyadmin
location ^~ /phpmyadmin {
    alias ${PMA_DIR};
    index index.php;

    location ~ ^/phpmyadmin/(libraries|setup|templates|tmp|vendor)/ {
        deny all;
    }
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$request_filename;
        fastcgi_param HTTP_PROXY "";
        fastcgi_pass unix:${sock};
    }
}
EOF
    cp "$PANEL_NGINX" "$GD_TMP/pterodactyl.conf.bak"
    if ! grep -q "germandactyl-phpmyadmin.conf" "$PANEL_NGINX"; then
        # Nach "index index.php;" im HTTPS-Block einfügen
        sed -i '0,/^\s*index index.php;/s##    index index.php;\n    include snippets/germandactyl-phpmyadmin.conf;#' "$PANEL_NGINX"
        grep -q "germandactyl-phpmyadmin.conf" "$PANEL_NGINX" || { echo "Einfügestelle in $PANEL_NGINX nicht gefunden."; return 1; }
    fi
    if ! nginx -t; then
        # Fehlerhafte Konfiguration sofort zurücknehmen, sonst startet nginx (und damit das Panel) nicht mehr
        cp "$GD_TMP/pterodactyl.conf.bak" "$PANEL_NGINX"
        rm -f "$PMA_SNIPPET"
        return 1
    fi
    systemctl reload nginx
    gd_conf_set PHPMYADMIN_VERSION "$version"
}

create_database_user() {
    PMA_USER="gd_admin_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 5)"
    PMA_PASSWORD="$(gd_gen_password 32)"
    gd_mysql <<SQL
CREATE USER '${PMA_USER}'@'localhost' IDENTIFIED BY '${PMA_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${PMA_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

# Alte Installation im Panel-Ordner (frühere Versionen dieses Skripts) wird bei jedem Panel-Update gelöscht
if [ -d "$PTERO_DIR/public/phpmyadmin" ]; then
    if gd_yesno "Alte phpMyAdmin-Installation" "phpMyAdmin liegt noch im Ordner des Panels. Dort wird es bei jedem Panel-Update gelöscht.\n\nSoll es entfernt und neu an einem sicheren Ort installiert werden?" 12 74; then
        rm -rf "$PTERO_DIR/public/phpmyadmin"
    else
        exit 0
    fi
fi

if [ -f "$PMA_DIR/config.inc.php" ] && grep -q "GermanDactyl" "$PMA_DIR/config.inc.php"; then
    if ! gd_yesno "📦 phpMyAdmin ist installiert" "phpMyAdmin (v$(gd_conf_get PHPMYADMIN_VERSION)) ist bereits installiert.\n\nMöchtest du es auf die neueste Version aktualisieren?" 11 70; then
        exit 0
    fi
    UPDATE_ONLY=true
fi

if [ ! -f "$PANEL_NGINX" ]; then
    gd_msg "Fehler" "Die nginx-Konfiguration des Panels wurde nicht gefunden ($PANEL_NGINX). Repariere zuerst die Erreichbarkeit über die Problembehandlung." 10 74
    exit 1
fi

if [ "${UPDATE_ONLY:-false}" != "true" ]; then
    gd_msg "👋 phpMyAdmin-Installation" "Bevor es losgeht, ein paar Hinweise:\n\n- phpMyAdmin ist öffentlich unter https://$(gd_conf_get PANEL_DOMAIN)/phpmyadmin erreichbar. Geschützt ist es nur durch die Zugangsdaten.\n- Verwende immer sichere Passwörter.\n- Der angelegte Benutzer hat vollen Zugriff auf alle Datenbanken." 15 74
fi

gd_gauge_open "📦 phpMyAdmin" "Installation wird vorbereitet..."
gd_step 20 "phpMyAdmin wird heruntergeladen und eingerichtet..." install_phpmyadmin
gd_progress 100 "Fertig."
gd_gauge_close

if [ "${UPDATE_ONLY:-false}" = "true" ]; then
    gd_msg "✅ phpMyAdmin aktualisiert" "phpMyAdmin wurde auf v$(gd_conf_get PHPMYADMIN_VERSION) aktualisiert." 8 60
    exit 0
fi

if ! create_database_user >> "$GD_LOG" 2>&1; then
    gd_msg "Fehler" "Der Datenbank-Benutzer konnte nicht angelegt werden. Details: $GD_LOG" 9 70
    exit 1
fi

while true; do
    gd_msg "🔑 Zugangsdaten für phpMyAdmin" "Adresse:       https://$(gd_conf_get PANEL_DOMAIN)/phpmyadmin\nBenutzername:  ${PMA_USER}\nPasswort:      ${PMA_PASSWORD}\n\nSpeichere dir diese Daten jetzt ab, sie werden nicht noch einmal angezeigt." 14 78
    gd_yesno "Zugangsdaten gespeichert?" "Hast du die Zugangsdaten gespeichert und funktionieren sie?" 8 60 && break
done
gd_msg "🎉 Einrichtung abgeschlossen" "Du kannst phpMyAdmin jetzt nutzen." 8 50
