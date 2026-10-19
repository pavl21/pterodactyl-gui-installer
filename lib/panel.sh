#!/bin/bash
# Pfad: lib/panel.sh
# Eigenständige Installation und Aktualisierung des Pterodactyl Panels nach offizieller Dokumentation
# (https://pterodactyl.io/panel/1.0/getting_started.html). Benötigt lib/common.sh und lib/germandactyl.sh.

GD_PANEL_DB="panel"
GD_PANEL_DB_USER="pterodactyl"

# ---------------------------------------------------------------------------
# Einzelschritte
# ---------------------------------------------------------------------------
gd_php_repo_check() {
    # gd_apt_update verschluckt Fehler der Paketquellen: Nach dem Einrichten der PHP-Quelle gezielt prüfen, ob die
    # gewünschte PHP-Version überhaupt installierbar ist (sonst folgt später nur "Unable to locate package")
    gd_apt_has_candidate "php${GD_PHP_VERSION}-fpm" && return 0
    echo "Paketquelle für PHP ${GD_PHP_VERSION} (${GD_OS_CODENAME}) liefert keine Pakete – apt-get update prüfen"
    return 1
}

gd_php_repo() {
    # PHP über das sury-Repository (Debian und Ubuntu, auch Ubuntu 26.04)
    gd_os_detect
    # Alte Einträge früherer Versionen dieses Skripts entfernen (doppelte Quellen führen zu apt-Fehlern)
    rm -f /etc/apt/sources.list.d/php.list /etc/apt/trusted.gpg.d/php.gpg
    # Ist bereits eine PHP-Quelle (sury oder ondrej-PPA) unter anderem Namen eingetragen, diese weiterverwenden –
    # zwei Einträge mit unterschiedlichem "signed-by" lassen apt mit "Conflicting values" abbrechen
    local existing
    existing="$(grep -rlsE 'packages\.sury\.org/php|ppa\.launchpad(content)?\.net/ondrej/php|ondrej-ubuntu-php' \
        /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v '/sury-php\.list$')"
    if [ -n "$existing" ]; then
        echo "Vorhandene PHP-Paketquelle wird verwendet: $(tr '\n' ' ' <<< "$existing")"
        rm -f /etc/apt/sources.list.d/sury-php.list
        gd_apt_update
        gd_php_repo_check
        return
    fi
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury-php.gpg || return 1
    echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${GD_OS_CODENAME} main" \
        > /etc/apt/sources.list.d/sury-php.list
    gd_apt_update
    gd_php_repo_check
}

gd_php_packages() {
    local v="$GD_PHP_VERSION"
    gd_apt_install "php${v}" "php${v}-cli" "php${v}-common" "php${v}-gd" "php${v}-mysql" "php${v}-mbstring" \
        "php${v}-bcmath" "php${v}-xml" "php${v}-fpm" "php${v}-curl" "php${v}-zip" "php${v}-intl" || return 1
    update-alternatives --set php "/usr/bin/php${v}" 2>/dev/null
    systemctl enable --now "php${v}-fpm"
}

gd_nginx_disable_default() {
    # Die Standardseite von nginx nur entfernen, wenn es die unveränderte Vorgabe ist. Sie lauscht auch auf
    # [::]:80 – auf Servern ohne IPv6 startet nginx deshalb direkt nach der Installation nicht.
    if [ -L /etc/nginx/sites-enabled/default ] && [ "$(readlink -f /etc/nginx/sites-enabled/default)" = "/etc/nginx/sites-available/default" ]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
    return 0
}

gd_apt_install_nostart() {
    # Pakete installieren, ohne dass deren Dienste automatisch starten: nginx scheitert sonst auf Servern
    # ohne IPv6 an der Standardseite ([::]:80) und dpkg bricht ab. Gestartet wird danach gezielt.
    # GD_OWN_POLICY ist global, damit gd_cleanup (Trap bei Strg+C/SSH-Abbruch) die Datei ebenfalls entfernen kann.
    local rc
    GD_OWN_POLICY=false
    export GD_OWN_POLICY
    if [ ! -e /usr/sbin/policy-rc.d ]; then
        # Die Kommentarzeile dient gd_cleanup als Erkennungsmerkmal
        printf '#!/bin/sh\n# germandactyl-setup\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d && GD_OWN_POLICY=true
    fi
    gd_apt_install "$@"
    rc=$?
    [ "$GD_OWN_POLICY" = true ] && rm -f /usr/sbin/policy-rc.d
    GD_OWN_POLICY=false
    return $rc
}

gd_certbot_timer_enable() {
    # Wird certbot unter policy-rc.d installiert (gd_apt_install_nostart), aktiviert das Debian-Paket seinen
    # certbot.timer nur, startet ihn aber nicht – die automatische Zertifikatserneuerung liefe dann nie.
    # Ein Fehler ist nicht fatal (z. B. Systeme ohne systemd oder Certbot per Snap).
    if systemctl cat certbot.timer >/dev/null 2>&1; then
        systemctl enable --now certbot.timer || echo "Hinweis: certbot.timer konnte nicht gestartet werden."
    fi
    return 0
}

gd_panel_packages() {
    gd_apt_install_nostart mariadb-server mariadb-client nginx redis-server tar unzip git cron \
        certbot python3-certbot-nginx || return 1
    gd_certbot_timer_enable
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    gd_nginx_disable_default
    systemctl enable --now mariadb redis-server cron || return 1
    systemctl enable nginx && systemctl restart nginx
}

gd_composer_install() {
    # Composer mit Prüfung der offiziellen Prüfsumme (SHA-384) installieren
    local expected actual
    expected="$(gd_curl https://composer.github.io/installer.sig)" || return 1
    gd_curl https://getcomposer.org/installer -o "$GD_TMP/composer-setup.php" || return 1
    actual="$(php -r "echo hash_file('sha384', '$GD_TMP/composer-setup.php');")"
    if [ "$expected" != "$actual" ]; then
        echo "Die Prüfsumme des Composer-Installers stimmt nicht überein – Abbruch."
        return 1
    fi
    php "$GD_TMP/composer-setup.php" --quiet --install-dir=/usr/local/bin --filename=composer
}

GD_REF_CACHE="/var/cache/germandactyl"            # Referenzbäume (Originalstand der installierten Version)
GD_BACKUP_CUSTOM_ROOT="/var/backups/germandactyl"  # Gesicherte eigene Änderungen und Rejects

gd_panel_need() {
    # gd_panel_need <lib> <funktion> – bindet lib/<lib>.sh ein, falls die Funktion noch nicht existiert
    declare -F "$2" >/dev/null || gd_source_lib "$1"
}

gd_panel_tarball_ok() {
    # gd_panel_tarball_ok <datei> – größer als 1 MB und ein lesbares gzip-tar-Archiv
    local size
    size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
    [ "$size" -gt 1048576 ] && tar -tzf "$1" >/dev/null 2>&1
}

gd_panel_fetch() {
    # gd_panel_fetch <version> [zieldatei] – lädt panel.tar.gz genau dieser Version (mit Wiederholungen) und prüft es.
    # Standardziel: $GD_TMP/panel-<version>.tar.gz. Ein bereits geladenes, gültiges Archiv wird wiederverwendet.
    # Das entpackte Panel wird dabei nicht verändert – so lässt sich vor dem Wartungsmodus laden und prüfen.
    # Upstream veröffentlicht keine Prüfsummen; geprüft werden Größe und Lesbarkeit des Archivs.
    local version="$1" file="${2:-$GD_TMP/panel-$1.tar.gz}"
    if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)?$ ]]; then
        echo "Ungültige Panel-Version: $version"
        return 1
    fi
    if [ -s "$file" ] && gd_panel_tarball_ok "$file"; then
        return 0
    fi
    rm -f "$file"
    if ! gd_curl "https://github.com/pterodactyl/panel/releases/download/v${version}/panel.tar.gz" -o "$file"; then
        rm -f "$file"
        echo "Der Download von Panel v${version} ist fehlgeschlagen (github.com erreichbar? Gibt es die Version?)."
        return 1
    fi
    if ! gd_panel_tarball_ok "$file"; then
        rm -f "$file"
        echo "Die heruntergeladene Datei ist kein gültiges Panel-Archiv (zu klein oder beschädigt)."
        return 1
    fi
    return 0
}

gd_panel_extract() {
    # gd_panel_extract <version> – entpackt das mit gd_panel_fetch geladene Archiv nach $PTERO_DIR
    local file="$GD_TMP/panel-$1.tar.gz"
    [ -s "$file" ] || { echo "Das Archiv $file fehlt (zuerst gd_panel_fetch aufrufen)."; return 1; }
    mkdir -p "$PTERO_DIR"
    tar -xzf "$file" -C "$PTERO_DIR" || return 1
    chmod -R 755 "$PTERO_DIR"/storage/* "$PTERO_DIR"/bootstrap/cache/
}

gd_panel_download() {
    # gd_panel_download <version> – lädt genau diese Version herunter und entpackt sie nach $PTERO_DIR (Installation)
    gd_panel_fetch "$1" && gd_panel_extract "$1"
}

gd_nginx_backup() {
    # gd_nginx_backup <site.conf> – vorhandene Site-Konfiguration vor dem Überschreiben sichern
    if [ -f "/etc/nginx/sites-available/$1" ]; then
        cp -p "/etc/nginx/sites-available/$1" "$GD_TMP/nginx-$1.bak"
    else
        rm -f "$GD_TMP/nginx-$1.bak"
    fi
}

gd_nginx_enabled_path() {
    # Wohin eine Site verlinkt wird: sites-enabled (Debian/Ubuntu-Paket) oder conf.d (Paket von nginx.org,
    # dessen nginx.conf sites-enabled nicht einbindet)
    if grep -qsE '^[[:space:]]*include[[:space:]]+/etc/nginx/sites-enabled/' /etc/nginx/nginx.conf; then
        echo "/etc/nginx/sites-enabled/$1"
    else
        echo "/etc/nginx/conf.d/$1"
    fi
}

gd_nginx_activate() {
    # gd_nginx_activate <site.conf> – aktivieren und testen; bei Fehler den vorherigen Stand
    # wiederherstellen, damit nginx (und andere Seiten auf dem Server) weiterlaufen
    local name="$1" link
    link="$(gd_nginx_enabled_path "$name")"
    mkdir -p "$(dirname "$link")"
    ln -sf "/etc/nginx/sites-available/$name" "$link" || return 1
    if nginx -t; then
        systemctl reload nginx || systemctl restart nginx
        return
    fi
    echo "Die neue nginx-Konfiguration ist fehlerhaft (siehe oben) – der vorherige Stand wird wiederhergestellt."
    if [ -f "$GD_TMP/nginx-$name.bak" ]; then
        cp -p "$GD_TMP/nginx-$name.bak" "/etc/nginx/sites-available/$name"
    else
        rm -f "$link"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    return 1
}

gd_nginx_http_config() {
    # Vorläufige Konfiguration nur für die Zertifikatsausstellung (Webroot-Verfahren)
    local domain="$1"
    gd_nginx_backup pterodactyl.conf
    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
# Angelegt von GermanDactyl Setup (vorläufig, wird nach der Zertifikatsausstellung ersetzt)
server {
    listen 80;
$(gd_has_ipv6 && echo "    listen [::]:80;")
    server_name ${domain};
    server_tokens off;
    root ${PTERO_DIR}/public;

    location /.well-known/acme-challenge/ {
        allow all;
    }
    location / {
        return 503;
    }
}
EOF
    gd_nginx_disable_default
    gd_nginx_activate pterodactyl.conf
}

gd_php_fpm_socket() {
    # Aktuell installierten PHP-FPM-Socket ermitteln (neueste Version zuerst)
    local sock
    sock="/run/php/php${GD_PHP_VERSION}-fpm.sock"
    if [ ! -S "$sock" ]; then
        sock="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1)"
    fi
    echo "${sock:-/run/php/php${GD_PHP_VERSION}-fpm.sock}"
}

gd_nginx_version() {
    # Gibt die installierte nginx-Version aus, z. B. 1.26.3 (leer, wenn nginx fehlt)
    nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

gd_nginx_http2_directive() {
    # Ab nginx 1.25.1 gilt die Direktive "http2 on;" – die alte Form "listen 443 ssl http2;" erzeugt dort bei
    # "nginx -t" eine Warnung. Ältere Versionen (Debian 12: 1.22, Ubuntu 22.04: 1.18, Ubuntu 24.04: 1.24) kennen
    # die neue Direktive nicht. Ist die Version unbekannt, bleibt es bei der alten Form (läuft überall).
    local v
    v="$(gd_nginx_version)"
    [ -n "$v" ] && gd_version_ge "$v" 1.25.1
}

gd_nginx_ssl_config() {
    # Offizielle SSL-Konfiguration (https://pterodactyl.io/panel/1.0/webserver_configuration.html)
    local domain="$1" sock listen4="listen 443 ssl http2;" listen6="listen [::]:443 ssl http2;" h2=false
    sock="$(gd_php_fpm_socket)"
    if gd_nginx_http2_directive; then
        listen4="listen 443 ssl;"
        listen6="listen [::]:443 ssl;"
        h2=true
    fi
    gd_nginx_backup pterodactyl.conf
    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
# Angelegt von GermanDactyl Setup – Grundlage: offizielle Pterodactyl-Dokumentation
server {
    listen 80;
$(gd_has_ipv6 && echo "    listen [::]:80;")
    server_name ${domain};
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root ${PTERO_DIR}/public;
        allow all;
    }
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    ${listen4}
$(gd_has_ipv6 && echo "    ${listen6}")
$($h2 && echo "    http2 on;")
    server_name ${domain};
    server_tokens off;

    root ${PTERO_DIR}/public;
    index index.php;
$( [ -f /etc/nginx/snippets/germandactyl-phpmyadmin.conf ] && echo "    include snippets/germandactyl-phpmyadmin.conf;" )

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    # allow larger file uploads and longer script runtimes
    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_session_cache shared:germandactyl_ssl:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    # See https://hstspreload.org/ before uncommenting the line below.
    # add_header Strict-Transport-Security "max-age=15768000; preload;";
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${sock};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    gd_nginx_activate pterodactyl.conf
}

gd_certbot_issue() {
    # gd_certbot_issue <domain> <email> – Zertifikat per Webroot (nginx läuft dabei weiter)
    local domain="$1" email="$2"
    gd_certbot_webroot "$domain" "$email" "${PTERO_DIR}/public"
}

gd_panel_ports_open() {
    # Ist die Firewall bereits aktiv, müssen Port 80 (Prüfung durch Let's Encrypt, Weiterleitung) und 443 offen sein
    if gd_ufw_active; then
        ufw allow 80/tcp comment "HTTP (Panel, Zertifikate)" >/dev/null
        ufw allow 443/tcp comment "HTTPS (Panel)" >/dev/null
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Zertifikate: Prüfung vorhandener Zertifikate und Umstellung des Erneuerungsverfahrens
# ---------------------------------------------------------------------------
gd_certbot_version() {
    # Gibt die Certbot-Version aus, z. B. 2.9.0 (leer, wenn certbot fehlt)
    certbot --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

gd_certbot_auth() {
    # gd_certbot_auth <name> – Verfahren, mit dem Certbot das Zertifikat erneuert (webroot, standalone, nginx, dns-cloudflare ...)
    awk -F' *= *' '$1=="authenticator"{print $2}' "/etc/letsencrypt/renewal/${1}.conf" 2>/dev/null
}

gd_cert_is_staging() {
    # gd_cert_is_staging <zertifikatsdatei> – stammt das Zertifikat von der Let's-Encrypt-Testumgebung?
    openssl x509 -noout -issuer -in "$1" 2>/dev/null | grep -qiE 'STAGING|Fake LE'
}

gd_cert_reusable() {
    # gd_cert_reusable <name> – Kann das vorhandene Zertifikat in /etc/letsencrypt/live/<name> bleiben?
    # Es muss noch mindestens 14 Tage gelten, zur Domain passen und darf nicht aus der Testumgebung stammen.
    # Setzt GD_CERT_DAYS (Resttage) und GD_CERT_REASON (Begründung, wenn nicht).
    local cert="/etc/letsencrypt/live/${1}/fullchain.pem"
    GD_CERT_DAYS="$(gd_cert_days_left "$cert" 2>/dev/null)"
    GD_CERT_REASON=""
    if [ -z "$GD_CERT_DAYS" ]; then
        GD_CERT_REASON="Zertifikat nicht lesbar"
    elif [ "$GD_CERT_DAYS" -lt 0 ]; then
        GD_CERT_REASON="abgelaufen"
    elif [ "$GD_CERT_DAYS" -lt 14 ]; then
        GD_CERT_REASON="läuft in ${GD_CERT_DAYS} Tagen ab"
    elif gd_cert_is_staging "$cert"; then
        GD_CERT_REASON="Zertifikat stammt aus der Let's-Encrypt-Testumgebung (Staging)"
    elif ! gd_cert_matches_domain "$cert" "$1"; then
        GD_CERT_REASON="Zertifikat gehört zu einer anderen Domain"
    fi
    [ -z "$GD_CERT_REASON" ]
}

gd_certbot_conf_rewrite() {
    # gd_certbot_conf_rewrite <conf-datei> <domain> <webroot|dns-cloudflare> <pfad>
    # Stellt die Erneuerungskonfiguration (/etc/letsencrypt/renewal/<name>.conf) auf ein anderes Verfahren um
    # (für Certbot unter 2.3 ohne "certbot reconfigure"). Webroot: authenticator, webroot_path und [[webroot_map]];
    # DNS: authenticator, Zugangsdaten-Datei und Wartezeit. Alte Einträge des anderen Verfahrens werden entfernt.
    local conf="$1" domain="$2" kind="$3" arg="$4" esc new names n
    grep -qE '^[[:space:]]*authenticator[[:space:]]*=' "$conf" || return 1
    esc="$(sed -e 's/[\\&|]/\\&/g' <<< "$arg")"
    case "$kind" in
        webroot) new="authenticator = webroot\\nwebroot_path = ${esc}," ;;
        dns-cloudflare) new="authenticator = dns-cloudflare\\ndns_cloudflare_credentials = ${esc}\\ndns_cloudflare_propagation_seconds = 30" ;;
        *) return 1 ;;
    esac
    sed -i -E \
        -e '/^\[\[webroot_map\]\]/,/^\[/{/^\[\[webroot_map\]\]/d;/^\[/!d}' \
        -e '/^[[:space:]]*(webroot_path|dns_cloudflare_credentials|dns_cloudflare_propagation_seconds|pref_challs)[[:space:]]*=/d' \
        -e "s|^[[:space:]]*authenticator[[:space:]]*=.*|${new}|" "$conf" || return 1
    if [ "$kind" = webroot ]; then
        # Für jeden Namen des Zertifikats (außer Wildcards) einen Webroot-Eintrag anlegen
        names="$(openssl x509 -noout -ext subjectAltName -in "/etc/letsencrypt/live/${domain}/cert.pem" 2>/dev/null | grep -oE 'DNS:[^, ]+' | cut -d: -f2)"
        [ -n "$names" ] || names="$domain"
        sed -i -e '$a\' "$conf"
        {
            echo "[[webroot_map]]"
            for n in $names; do
                [[ "$n" == \** ]] && continue
                echo "$n = $arg"
            done
        } >> "$conf"
    fi
}

gd_certbot_switch_auth() {
    # gd_certbot_switch_auth <name> webroot <webroot-pfad> | dns-cloudflare <zugangsdaten-datei>
    # Stellt nur die Erneuerung eines vorhandenen Zertifikats um – es wird nichts neu ausgestellt (das würde gegen das
    # Let's-Encrypt-Limit von 5 Duplikaten pro Woche zählen). Certbot ab 2.3: "certbot reconfigure", sonst wird die
    # Erneuerungskonfiguration angepasst (Sicherung vorher nach <conf>.germandactyl.bak). Zur Kontrolle folgt ein
    # Testlauf der Erneuerung; scheitert er, wird der alte Stand wiederhergestellt (Rückgabe 1).
    local name="$1" kind="$2" arg="$3" conf bak rc=1
    conf="/etc/letsencrypt/renewal/${name}.conf"
    bak="${conf}.germandactyl.bak"
    [ -f "$conf" ] || return 1
    cp -p "$conf" "$bak" || return 1
    if gd_version_ge "$(gd_certbot_version)" 2.3; then
        echo "Erneuerung von ${name} wird mit 'certbot reconfigure' auf ${kind} umgestellt..."
        case "$kind" in
            webroot)
                certbot reconfigure --cert-name "$name" --webroot -w "$arg" --non-interactive && rc=0 ;;
            dns-cloudflare)
                certbot reconfigure --cert-name "$name" --dns-cloudflare --dns-cloudflare-credentials "$arg" \
                    --dns-cloudflare-propagation-seconds 30 --non-interactive && rc=0 ;;
        esac
    else
        echo "Certbot $(gd_certbot_version) hat kein 'reconfigure' – Erneuerung von ${name} wird in ${conf} auf ${kind} umgestellt (Sicherung: ${bak})."
        gd_certbot_conf_rewrite "$conf" "$name" "$kind" "$arg" && rc=0
    fi
    if [ $rc -eq 0 ]; then
        echo "Kontrolle: Testlauf der Erneuerung (certbot renew --dry-run)..."
        certbot renew --cert-name "$name" --dry-run || rc=1
    fi
    if [ $rc -ne 0 ]; then
        cp -p "$bak" "$conf"
        echo "Die Umstellung ist fehlgeschlagen – die ursprüngliche Erneuerungskonfiguration wurde wiederhergestellt."
        return 1
    fi
    return 0
}

gd_certbot_webroot() {
    # gd_certbot_webroot <domain> <email> <webroot> – Zertifikat per Webroot. Ein vorhandenes Zertifikat bleibt
    # erhalten, wenn es noch mindestens 14 Tage gilt, zur Domain passt und nicht aus der Testumgebung stammt. War es
    # per "standalone" ausgestellt (scheitert später an nginx auf Port 80), wird nur die Erneuerung auf Webroot
    # umgestellt. Neu ausgestellt wird (mit --force-renewal) nur, wenn das Zertifikat unbrauchbar ist oder die
    # Umstellung scheitert – jede Neuausstellung zählt gegen das Let's-Encrypt-Limit (5 Duplikate pro Woche).
    local domain="$1" email="$2" webroot="$3" cert conf auth extra=()
    cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    conf="/etc/letsencrypt/renewal/${domain}.conf"
    gd_panel_ports_open
    if [ -f "$cert" ]; then
        if gd_cert_reusable "$domain"; then
            auth="$(gd_certbot_auth "$domain")"
            if [ "$auth" != "standalone" ]; then
                echo "Zertifikat für ${domain} ist bereits vorhanden (noch ${GD_CERT_DAYS} Tage gültig)."
                return 0
            fi
            echo "Zertifikat für ${domain} ist noch ${GD_CERT_DAYS} Tage gültig, wurde aber per 'standalone' ausgestellt – nur die Erneuerung wird auf Webroot umgestellt."
            gd_certbot_switch_auth "$domain" webroot "$webroot" && return 0
            echo "Die Umstellung hat nicht funktioniert – das Zertifikat wird neu ausgestellt."
        else
            echo "Vorhandenes Zertifikat für ${domain} wird neu ausgestellt (${GD_CERT_REASON})."
        fi
        extra=(--force-renewal)
    elif [ -e "$conf" ]; then
        # Reste eines gelöschten Zertifikats würden certbot blockieren
        certbot delete --cert-name "$domain" --non-interactive
    fi
    gd_certbot_mail_args "$email"
    certbot certonly --webroot -w "$webroot" -d "$domain" --cert-name "$domain" "${extra[@]}" \
        "${GD_CERTBOT_MAIL[@]}" --agree-tos --no-eff-email --non-interactive
}

# ---------------------------------------------------------------------------
# Zertifikate per DNS-Challenge über Cloudflare (optional, z. B. wenn der Cloudflare-Proxy aktiv bleiben soll)
# ---------------------------------------------------------------------------
GD_CF_INI="/etc/letsencrypt/cloudflare.ini"
# Vorausgefüllter Link: Berechtigungen Zone:DNS:Edit und Zone:Zone:Read, Name "GermanDactyl Setup"
GD_CF_TOKEN_URL='https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%5D&accountId=%2A&zoneId=all&name=GermanDactyl%20Setup'

gd_cloudflare_token_check() {
    # gd_cloudflare_token_check <token> – prüft den Token über die Cloudflare-API.
    # Rückgabe: 0 = gültig, 1 = ungültig oder nicht aktiv, 2 = Cloudflare nicht erreichbar, 3 = Token sieht keine Zone
    # Den Token als Header aus einer privaten Datei übergeben ("-H @datei"): als curl-Argument stünde er in der
    # Prozessliste und wäre für alle lokalen Benutzer sichtbar
    local token="$1" hdr res
    hdr="$(umask 077; mktemp "${GD_TMP:-/tmp}/cf-auth.XXXXXX")" || return 2
    printf 'Authorization: Bearer %s\n' "$token" > "$hdr"
    res="$(curl -s --max-time 20 -H "@${hdr}" https://api.cloudflare.com/client/v4/user/tokens/verify | tr -d ' \n')"
    if [ -z "$res" ]; then
        rm -f "$hdr"
        return 2
    fi
    if ! grep -q '"success":true' <<< "$res" || ! grep -q '"status":"active"' <<< "$res"; then
        rm -f "$hdr"
        return 1
    fi
    # Zone:Zone:Read prüfen – ohne sieht der Token keine Domain, und die DNS-Challenge scheitert später
    res="$(curl -s --max-time 20 -H "@${hdr}" 'https://api.cloudflare.com/client/v4/zones?per_page=1' | tr -d ' \n')"
    rm -f "$hdr"
    if grep -q '"success":true' <<< "$res" && ! grep -q '"result":\[\]' <<< "$res"; then
        return 0
    fi
    return 3
}

gd_cloudflare_token_ask() {
    # Fragt einen Cloudflare API-Token ab, prüft ihn und speichert ihn nur lokal in /etc/letsencrypt/cloudflare.ini
    # (Rechte 600). Rückgabe 0 = Token gespeichert (oder vorhandener gültiger Token behalten), 1 = Abbruch.
    local token rc
    if [ -s "$GD_CF_INI" ]; then
        token="$(sed -nE 's/^[[:space:]]*dns_cloudflare_api_token[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$GD_CF_INI" | head -n1)"
        if [ -n "$token" ] && gd_cloudflare_token_check "$token"; then
            if gd_yesno "☁ Cloudflare API-Token" "Es ist bereits ein gültiger Cloudflare API-Token gespeichert:\n\n${GD_CF_INI}\n\nSoll dieser Token weiterverwendet werden?" 12 74; then
                chmod 600 "$GD_CF_INI"
                return 0
            fi
        fi
    fi
    token=""
    gd_msg "☁ Cloudflare API-Token erstellen" "Für die DNS-Challenge braucht GermanDactyl Setup einen Cloudflare API-Token. Er wird nur lokal in ${GD_CF_INI} gespeichert (nur für root lesbar) – nie im Log und nie in den Einstellungen.\n\nErstelle ihn über diesen Link (Berechtigungen Zone:DNS:Edit und Zone:Zone:Read sind vorausgefüllt):\n\n${GD_CF_TOKEN_URL}\n\nCloudflare zeigt den Token nur ein einziges Mal an. Kopiere ihn und füge ihn im nächsten Fenster ein." 22 78
    while true; do
        token="$(gd_whip --title "☁ Cloudflare API-Token" --passwordbox "Füge den Cloudflare API-Token ein (die Eingabe bleibt unsichtbar):" 10 74 3>&1 1>&2 2>&3)" || return 1
        token="$(tr -d '[:space:]' <<< "$token")"
        if ! [[ "$token" =~ ^[A-Za-z0-9_.-]{20,}$ ]]; then
            gd_msg "Token ungültig" "Das sieht nicht nach einem Cloudflare API-Token aus. Er besteht nur aus Buchstaben, Zahlen, '-' und '_' und ist etwa 40 Zeichen lang.\n\nBitte kopiere ihn erneut, ohne Leerzeichen." 12 70
            continue
        fi
        gd_cloudflare_token_check "$token"
        rc=$?
        case "$rc" in
            0) break ;;
            2) gd_msg "Cloudflare nicht erreichbar" "Die Cloudflare-API (api.cloudflare.com) ist von diesem Server aus nicht erreichbar. Prüfe die Internetverbindung und versuche es erneut." 10 70 ;;
            3) gd_msg "Token ohne Zugriff auf Zonen" "Der Token ist gültig, sieht aber keine Domain (Zone). Erstelle ihn mit dem vorausgefüllten Link und wähle bei 'Zonenressourcen' die Zone deiner Domain bzw. 'Alle Zonen'. Es werden Zone:DNS:Edit und Zone:Zone:Read benötigt." 13 74 ;;
            *) gd_msg "Token ungültig" "Cloudflare hat den Token abgelehnt (ungültig, abgelaufen oder deaktiviert).\n\nPrüfe, ob du ihn vollständig kopiert hast, oder erstelle einen neuen Token." 11 70 ;;
        esac
    done
    ( umask 077; mkdir -p "$(dirname "$GD_CF_INI")"; printf 'dns_cloudflare_api_token = %s\n' "$token" > "$GD_CF_INI" ) \
        || { token=""; gd_msg "Fehler" "Die Datei ${GD_CF_INI} konnte nicht geschrieben werden." 9 70; return 1; }
    chmod 600 "$GD_CF_INI"
    token=""
    gd_log "Cloudflare API-Token geprüft und in ${GD_CF_INI} gespeichert (Inhalt wird nicht protokolliert)"
    return 0
}

gd_certbot_dns_cloudflare() {
    # gd_certbot_dns_cloudflare <domain> <email> – Zertifikat per DNS-Challenge über Cloudflare (benötigt
    # /etc/letsencrypt/cloudflare.ini aus gd_cloudflare_token_ask). Ein noch gültiges Zertifikat wird nicht neu
    # ausgestellt, es wird nur die Erneuerung auf dns-cloudflare umgestellt (Neuausstellung zählt gegen das Limit).
    local domain="$1" email="$2" cert conf auth extra=()
    cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    conf="/etc/letsencrypt/renewal/${domain}.conf"
    if [ ! -s "$GD_CF_INI" ]; then
        echo "Die Zugangsdaten-Datei ${GD_CF_INI} fehlt – es wurde kein Cloudflare API-Token hinterlegt."
        return 1
    fi
    chmod 600 "$GD_CF_INI"
    command -v certbot >/dev/null 2>&1 || gd_apt_install certbot || return 1
    certbot plugins 2>/dev/null | grep -q 'dns-cloudflare' || gd_apt_install python3-certbot-dns-cloudflare || return 1
    if [ -f "$cert" ]; then
        if gd_cert_reusable "$domain"; then
            auth="$(gd_certbot_auth "$domain")"
            if [ "$auth" = "dns-cloudflare" ]; then
                echo "Zertifikat für ${domain} ist bereits vorhanden (noch ${GD_CERT_DAYS} Tage gültig, Erneuerung per Cloudflare)."
                return 0
            fi
            echo "Zertifikat für ${domain} ist noch ${GD_CERT_DAYS} Tage gültig – nur die Erneuerung wird auf Cloudflare (DNS-01) umgestellt."
            gd_certbot_switch_auth "$domain" dns-cloudflare "$GD_CF_INI" && return 0
            echo "Die Umstellung hat nicht funktioniert – das Zertifikat wird neu ausgestellt."
        else
            echo "Vorhandenes Zertifikat für ${domain} wird neu ausgestellt (${GD_CERT_REASON})."
        fi
        extra=(--force-renewal)
    elif [ -e "$conf" ]; then
        certbot delete --cert-name "$domain" --non-interactive
    fi
    gd_certbot_mail_args "$email"
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$GD_CF_INI" --dns-cloudflare-propagation-seconds 30 \
        -d "$domain" --cert-name "$domain" "${extra[@]}" "${GD_CERTBOT_MAIL[@]}" --agree-tos --no-eff-email --non-interactive
}

gd_ssl_method_ask() {
    # gd_ssl_method_ask <domain> – setzt GD_SSL_METHOD (webroot oder cloudflare). Standard ist Webroot ohne
    # Rückfrage. Nur wenn die Domain über den Cloudflare-Proxy läuft (orange Wolke), kann Let's Encrypt den Server
    # nicht direkt erreichen: Dann gibt es die Wahl zwischen Proxy ausschalten und DNS-Challenge per API-Token.
    # Rückgabe 1 bei Abbruch.
    local domain="$1" ip choice
    GD_SSL_METHOD=webroot
    ip="$(gd_resolve_a "$domain" | head -n1)"
    gd_is_cloudflare_ip "$ip" || return 0
    while true; do
        choice="$(gd_whip --title "☁ Cloudflare-Proxy erkannt" --menu "Die Domain ${domain} läuft über den Cloudflare-Proxy (orange Wolke). Let's Encrypt kann den Server darüber nicht direkt prüfen.\n\nMit einem Cloudflare API-Token (DNS-01) kann der Proxy für das Panel an bleiben. Wings braucht trotzdem einen direkt erreichbaren FQDN ohne Proxy.\n\nWie soll das SSL-Zertifikat ausgestellt werden?" 21 78 2 \
            "1" "Cloudflare-Proxy ausschalten (DNS only), Webroot nutzen" \
            "2" "Cloudflare API-Token für DNS-01 verwenden" 3>&1 1>&2 2>&3)" || return 1
        case "$choice" in
            1)
                gd_msg "☁ Proxy ausschalten" "Öffne das Cloudflare-Dashboard, wähle deine Domain unter 'DNS' und klicke beim Eintrag von ${domain} auf die orange Wolke, bis sie grau ist ('Nur DNS').\n\nDie Änderung wirkt nach wenigen Minuten. Im Anschluss wird die Domain erneut geprüft." 13 74
                if gd_dns_check_dialog "$domain"; then
                    GD_SSL_METHOD=webroot
                    return 0
                fi ;;
            2)
                if gd_cloudflare_token_ask; then
                    GD_SSL_METHOD=cloudflare
                    return 0
                fi ;;
        esac
    done
}

gd_panel_database() {
    # Datenbank und Benutzer anlegen (nur Rechte auf die Panel-Datenbank)
    local pw="$1"
    gd_mysql <<SQL
CREATE USER IF NOT EXISTS '${GD_PANEL_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${pw}';
ALTER USER '${GD_PANEL_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${pw}';
CREATE DATABASE IF NOT EXISTS \`${GD_PANEL_DB}\`;
GRANT ALL PRIVILEGES ON \`${GD_PANEL_DB}\`.* TO '${GD_PANEL_DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

gd_panel_db_has_tables() {
    local n
    n="$(gd_mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${GD_PANEL_DB}';" 2>/dev/null)"
    [ "${n:-0}" -gt 0 ]
}

gd_panel_composer() {
    cd "$PTERO_DIR" || return 1
    # Die .env enthält später APP_KEY und Datenbank-Passwort: von Anfang an nicht für alle Benutzer lesbar
    # (umask 027 -> 640). Besitzer wie am Ende von gd_panel_permissions, damit der Zustand durchgehend gleich bleibt.
    if [ ! -f .env ]; then
        (umask 027; cp .env.example .env) || return 1
        chown www-data:www-data .env
    fi
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
}

gd_env_set() {
    # gd_env_set KEY WERT – setzt einen Wert in der .env des Panels (Sonderzeichen im Wert sind erlaubt,
    # die Datei behält Rechte 640; siehe gd_dotenv_set in lib/common.sh)
    gd_dotenv_set "$PTERO_DIR/.env" "$1" "$2"
}

gd_panel_configure() {
    # gd_panel_configure <domain> <email> <db-passwort> <telemetrie true/false>
    local domain="$1" email="$2" dbpw="$3" telemetry="$4"
    cd "$PTERO_DIR" || return 1
    # Gehärteter Redis mit Passwort (requirepass) – sonst Fehler 500 bei Sitzungen
    local rpass
    rpass="$(awk '$1=="requirepass"{print $2}' /etc/redis/redis.conf 2>/dev/null | tail -n1 | tr -d '"')"
    php artisan key:generate --force || return 1
    # Passwörter nicht als Befehlsargument übergeben (für alle lokalen Benutzer per "ps" sichtbar), sondern
    # vorab in die .env schreiben. Ohne --redis-pass und mit --no-interaction behält p:environment:setup ein
    # bereits gesetztes REDIS_PASSWORD bei (die Rückfrage "ändern?" wird dann mit Nein beantwortet); ohne
    # Passwort setzt der Befehl selbst "null". Enthält das Passwort Sonderzeichen, wird es wie vom Panel
    # selbst (escapeEnvironmentValue) in Anführungszeichen geschrieben.
    if [ -n "$rpass" ]; then
        if [[ "$rpass" =~ [^A-Za-z0-9_.+/-] ]]; then
            rpass="\"$(sed -e 's/[\\"'"'"']/\\&/g' <<< "$rpass")\""
        fi
        gd_env_set REDIS_PASSWORD "$rpass" || return 1
    fi
    php artisan p:environment:setup --no-interaction \
        --author="${email:-$(gd_admin_email "" "$domain")}" --url="https://${domain}" --timezone="$GD_TIMEZONE" \
        --cache=redis --session=redis --queue=redis \
        --redis-host=127.0.0.1 --redis-port=6379 \
        --settings-ui=true --telemetry="$telemetry" || return 1
    # Das Panel wertet --telemetry=false fehlerhaft aus (Operator-Rangfolge), daher explizit setzen
    gd_env_set PTERODACTYL_TELEMETRY_ENABLED "$telemetry"
    # Datenbank-Zugang direkt in die .env schreiben, statt "p:environment:database --password=...": Das Passwort
    # stünde sonst als Argument in der Prozessliste, und der Befehl lässt sich mit --no-interaction nicht ohne
    # --password nutzen (er würde das vorhandene Passwort durch ein leeres ersetzen und scheitern). Genau diese
    # fünf Variablen schreibt der Befehl auch; ob die Verbindung stimmt, prüft gleich "migrate".
    gd_env_set DB_HOST 127.0.0.1 && gd_env_set DB_PORT 3306 && gd_env_set DB_DATABASE "$GD_PANEL_DB" \
        && gd_env_set DB_USERNAME "$GD_PANEL_DB_USER" && gd_env_set DB_PASSWORD "$dbpw" || return 1
    php artisan migrate --seed --force
}

gd_user_set_password() {
    # gd_user_set_password <Benutzer-Modellklasse> <benutzername> <passwort> <artisan-aufruf...>
    # z. B.: gd_user_set_password '\Pterodactyl\Models\User' admin "$pw" php artisan
    # Setzt das Passwort eines vorhandenen Benutzers. Benutzername und Passwort gehen per Umgebungsvariable
    # an PHP und stehen nicht in der Prozessliste (Argumente von "ps" sieht jeder lokale Benutzer, die
    # Umgebung eines fremden Prozesses nicht). Der Hash entsteht mit demselben Hasher wie im Panel.
    local model="$1" user="$2" pw="$3" code out
    shift 3
    code="echo (${model}::where('username', getenv('GD_PW_USER'))->update(['password' => \\Illuminate\\Support\\Facades\\Hash::make(getenv('GD_PW'))]) === 1) ? 'GD_PW_OK' : 'GD_PW_FEHLER';"
    out="$(GD_PW_USER="$user" GD_PW="$pw" "$@" tinker --execute="$code" 2>&1)"
    grep -q 'GD_PW_OK' <<< "$out" && return 0
    echo "$out"
    return 1
}

gd_panel_admin() {
    # gd_panel_admin <email> <benutzername> <passwort>
    # Das Konto wird ohne Passwort angelegt (--no-password) und das Passwort danach gesetzt – "--password=..."
    # wäre für alle lokalen Benutzer in der Prozessliste sichtbar.
    cd "$PTERO_DIR" || return 1
    php artisan p:user:make --no-interaction --email="$1" --username="$2" \
        --name-first=Admin --name-last=User --no-password --admin=1 || return 1
    gd_user_set_password '\Pterodactyl\Models\User' "$2" "$3" php artisan
}

gd_panel_permissions() {
    chown -R www-data:www-data "$PTERO_DIR"
    chmod 640 "$PTERO_DIR/.env"
}

gd_panel_cron() {
    # Cronjob für die Zeitpläne des Panels (schedule:run) als Benutzer www-data: Läuft er als root, legt das Panel
    # root-eigene Dateien in storage/ an, und der Webserver (www-data) scheitert danach mit Fehler 500.
    # Bestehende Installationen werden migriert: ein root-Eintrag für dieses Panel wird entfernt. Andere Einträge bleiben.
    # Läuft bei der Installation und bei jedem Update.
    local marker="${PTERO_DIR}/artisan schedule:run" cron_line root_tab www_tab rest
    cron_line="* * * * * php ${PTERO_DIR}/artisan schedule:run >> /dev/null 2>&1"
    command -v crontab >/dev/null 2>&1 || gd_apt_install cron || return 1
    www_tab="$(crontab -u www-data -l 2>/dev/null | grep -vF "$marker")"
    { [ -n "$www_tab" ] && printf '%s\n' "$www_tab"; echo "$cron_line"; } | crontab -u www-data - || return 1
    root_tab="$(crontab -l 2>/dev/null)"
    if grep -qF "$marker" <<< "$root_tab"; then
        echo "Der Cronjob lief bisher als root und wird auf www-data umgestellt."
        rest="$(grep -vF "$marker" <<< "$root_tab")"
        if [ -n "$rest" ]; then
            printf '%s\n' "$rest" | crontab - || return 1
        else
            crontab -r || return 1
        fi
    fi
    return 0
}

gd_panel_services() {
    # Cronjob (als www-data) und Queue-Worker
    gd_panel_cron || return 1

    cat > /etc/systemd/system/pteroq.service <<EOF
# Pterodactyl Queue Worker File
# ----------------------------------

[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
# On some systems the user and group might be different.
# Some systems use \`apache\` or \`nginx\` as the user and group.
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php ${PTERO_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now redis-server pteroq
}

gd_panel_healthcheck() {
    # Prüft lokal (ohne Umweg über den Router), ob das Panel per HTTPS antwortet
    local domain="$1" code i
    for i in 1 2 3 4 5; do
        code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${domain}:443:127.0.0.1" "https://${domain}/auth/login")"
        echo "HTTP-Status der Anmeldeseite: $code"
        case "$code" in 200|302) return 0 ;; esac
        sleep 3
    done
    return 1
}

gd_artisan_www() {
    # Artisan-Befehle als Webserver-Benutzer ausführen (verhindert root-eigene Log-/Cache-Dateien)
    # HOME=/tmp, da www-data kein beschreibbares Home-Verzeichnis hat (tinker legt dort Dateien an)
    (cd "$PTERO_DIR" && runuser -u www-data -- env HOME=/tmp php artisan "$@")
}

# ---------------------------------------------------------------------------
# Komplette Installation (wird aus installer.sh aufgerufen)
# ---------------------------------------------------------------------------
gd_panel_install_steps() {
    # Erwartet: GD_DOMAIN, GD_EMAIL (darf leer sein = anonym), GD_ADMIN_USER, GD_ADMIN_PASSWORD, GD_DB_PASSWORD, GD_TELEMETRY,
    #           GD_PANEL_VERSION, GD_APPLY_PATCH (aus gd_choose_panel_version), optional GD_SSL_METHOD (webroot|cloudflare)
    # Markierung: Bricht die Installation ab, erkennt der nächste Start die unvollständige Installation
    gd_conf_set INSTALL_STATE laeuft
    local admin_email
    admin_email="${GD_ADMIN_EMAIL:-$(gd_admin_email "$GD_EMAIL" "$GD_DOMAIN")}"
    gd_step 2  "Paketquellen werden aktualisiert..." gd_apt_update
    gd_step 5  "PHP ${GD_PHP_VERSION}-Paketquelle wird eingerichtet..." gd_php_repo
    gd_step 10 "PHP ${GD_PHP_VERSION} wird installiert..." gd_php_packages
    gd_step 18 "MariaDB, Redis, nginx und Certbot werden installiert..." gd_panel_packages
    gd_step 24 "Composer wird installiert..." gd_composer_install
    gd_step 27 "Pterodactyl Panel v${GD_PANEL_VERSION} wird heruntergeladen..." gd_panel_download "$GD_PANEL_VERSION"
    gd_step 30 "Webserver wird für das SSL-Zertifikat vorbereitet..." gd_nginx_http_config "$GD_DOMAIN"
    if [ "${GD_SSL_METHOD:-webroot}" = "cloudflare" ]; then
        # Panel hinter dem Cloudflare-Proxy: Let's Encrypt prüft per DNS-Eintrag (API-Token), nicht über Port 80
        gd_panel_ports_open >> "$GD_LOG" 2>&1
        gd_step 33 "SSL-Zertifikat wird über Cloudflare (DNS-01) angefordert..." gd_certbot_dns_cloudflare "$GD_DOMAIN" "$GD_EMAIL"
    else
        gd_step 33 "SSL-Zertifikat wird bei Let's Encrypt angefordert..." gd_certbot_issue "$GD_DOMAIN" "$GD_EMAIL"
    fi
    gd_step 36 "Webserver wird mit SSL eingerichtet..." gd_nginx_ssl_config "$GD_DOMAIN"
    gd_step 37 "Automatische Zertifikatserneuerung wird eingerichtet..." gd_certbot_hook
    gd_step 39 "Datenbank für das Panel wird angelegt..." gd_panel_database "$GD_DB_PASSWORD"
    gd_step 42 "Composer-Abhängigkeiten werden installiert (dauert etwas)..." gd_panel_composer
    gd_step 52 "Panel wird konfiguriert und die Datenbank eingerichtet..." gd_panel_configure "$GD_DOMAIN" "$GD_EMAIL" "$GD_DB_PASSWORD" "$GD_TELEMETRY"
    gd_step 58 "Administrator-Konto wird angelegt..." gd_panel_admin "$admin_email" "$GD_ADMIN_USER" "$GD_ADMIN_PASSWORD"
    gd_step 60 "Berechtigungen werden gesetzt..." gd_panel_permissions
    gd_step 62 "Cronjob und Hintergrunddienst (Queue) werden eingerichtet..." gd_panel_services
    # Reihenfolge wichtig: Blueprint ersetzt Dateien der Oberfläche, die Übersetzung kommt danach
    if [ "${GD_BLUEPRINT:-false}" = "true" ]; then
        gd_blueprint_install_step 63 latest
    fi
    if [ "$GD_APPLY_PATCH" = "true" ]; then
        gd_germandactyl_steps 64
    fi
    gd_step 70 "Panel wird auf Erreichbarkeit geprüft..." gd_panel_healthcheck "$GD_DOMAIN"

    gd_conf_set PANEL_DOMAIN "$GD_DOMAIN"
    gd_conf_set PANEL_EMAIL "$GD_EMAIL"
    gd_conf_set PANEL_VERSION "$GD_PANEL_VERSION"
}

# ---------------------------------------------------------------------------
# Aktualisierung / Reparatur einer bestehenden Installation
# ---------------------------------------------------------------------------
gd_php_current() {
    php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null
}

gd_php_migrate() {
    # Ältere Installationen (z. B. PHP 8.1) auf die benötigte PHP-Version umstellen
    gd_php_repo || return 1
    gd_php_packages || return 1
    if [ -f /etc/nginx/sites-available/pterodactyl.conf ]; then
        sed -i -E "s#unix:/run/php/php[0-9]+\.[0-9]+-fpm\.sock#unix:/run/php/php${GD_PHP_VERSION}-fpm.sock#" \
            /etc/nginx/sites-available/pterodactyl.conf
    fi
    nginx -t && systemctl reload nginx
}

gd_panel_installed_version() {
    grep "'version' =>" "$PTERO_DIR/config/app.php" 2>/dev/null | cut -d\' -f4
}

# ---------------------------------------------------------------------------
# Erkennung eigener Änderungen: Vergleich mit dem Originalstand der installierten Version
# ---------------------------------------------------------------------------
GD_PANEL_CHECK_DIRS=(app resources routes config database public)

gd_panel_translation_for() {
    # gd_panel_translation_for <version> – gehört die installierte deutsche Übersetzung (GermanDactyl) zu dieser Version?
    # Wurde das Panel später ohne Übersetzung aktualisiert, steht in der Konfiguration noch die alte Version.
    [ -n "$1" ] && [ "$(gd_conf_get GD_GERMANDACTYL)" = "$1" ]
}

gd_panel_reference_cache() {
    # gd_panel_reference_cache <version> – Pfad des Referenzbaums im Cache (mit Übersetzung: panel-<version>-de)
    local suffix=""
    gd_panel_translation_for "$1" && suffix="-de"
    echo "$GD_REF_CACHE/panel-$1$suffix"
}

gd_panel_reference_tree() {
    # gd_panel_reference_tree <version> <zielverzeichnis> – baut den Originalstand der Panel-Version auf (panel.tar.gz,
    # bei installierter Übersetzung zusätzlich mit dem GermanDactyl-Patch) und legt ihn unter <zielverzeichnis> ab.
    # Der Referenzbaum wird pro Version einmal unter /var/cache/germandactyl/panel-<version>[-de]/ (Rechte 700)
    # gehalten und wiederverwendet; ist <zielverzeichnis> dieser Pfad (gd_panel_reference_cache), wird nichts kopiert.
    # Setzt GD_REFERENCE_DIR. Rückgabe 1, wenn der Aufbau nicht möglich ist (Download, Archiv, Patch).
    local version="$1" target="$2" cache build tarball
    [ -n "$version" ] && [ -n "$target" ] || return 1
    cache="$(gd_panel_reference_cache "$version")"
    if [ ! -f "$cache/.gd-referenz-fertig" ]; then
        install -d -m 700 "$GD_REF_CACHE" || return 1
        build="$cache.neu.$$"
        rm -rf "$build"
        mkdir -p "$build" && chmod 700 "$build" || return 1
        tarball="$GD_TMP/panel-referenz-$version.tar.gz"
        if ! gd_panel_fetch "$version" "$tarball" || ! tar -xzf "$tarball" -C "$build"; then
            rm -rf "$build" "$tarball"
            return 1
        fi
        rm -f "$tarball"
        if gd_panel_translation_for "$version"; then
            # In einer Subshell: gd_patch_apply wechselt das Verzeichnis und meldet Teilergebnisse über GD_WARNINGS,
            # die hier niemanden betreffen
            if ! ( GD_WARNINGS=""; gd_patch_apply "$version" "$build" ); then
                echo "Die Übersetzung v${version} konnte nicht auf den Referenzstand angewendet werden."
                rm -rf "$build"
                return 1
            fi
        fi
        : > "$build/.gd-referenz-fertig"
        chmod 700 "$build"
        rm -rf "$cache"
        mv "$build" "$cache" || { rm -rf "$build"; return 1; }
        # Referenzen anderer Versionen werden nicht mehr gebraucht
        find "$GD_REF_CACHE" -mindepth 1 -maxdepth 1 -name 'panel-*' ! -name "panel-${version}" ! -name "panel-${version}-de" \
            -exec rm -rf {} + 2>/dev/null
    fi
    if [ "$target" != "$cache" ]; then
        rm -rf "$target"
        mkdir -p "$target" && cp -a "$cache/." "$target/" || return 1
    fi
    GD_REFERENCE_DIR="$target"
    return 0
}

gd_panel_change_exclude() {
    # Ausdruck (egrep) für Pfade, die beim Vergleich nicht zählen: Laufzeitdaten, gebaute Oberfläche, Blueprint-Verwaltung,
    # Reste von Patches und – bei installierter Übersetzung – die Sprachdateien (Referenz enthält sie bereits)
    local ex='^(public/assets/|public/build/|public/\.well-known/|\.blueprint/|storage/|vendor/|node_modules/|bootstrap/cache/)'
    ex+='|(^|/)node_modules/|\.(rej|orig)$|(^|/)\.gd-referenz-fertig$|(^|/)\.env$'
    if [ -n "$(gd_conf_get GD_GERMANDACTYL)" ]; then
        ex+='|^resources/lang/de(/|\.json$)'
    fi
    echo "$ex"
}

gd_panel_hashes() {
    # gd_panel_hashes <basisverzeichnis> <ausschlussausdruck> – "<sha256>  <relativer pfad>" je Datei in den geprüften Ordnern
    local d dirs=()
    for d in "${GD_PANEL_CHECK_DIRS[@]}"; do
        [ -d "$1/$d" ] && dirs+=("$d")
    done
    [ ${#dirs[@]} -gt 0 ] || return 0
    ( cd "$1" && find "${dirs[@]}" -type f -print0 | grep -zvE "$2" | xargs -0 -r sha256sum ) | LC_ALL=C sort -k2
}

gd_panel_detect_changes() {
    # gd_panel_detect_changes <installierte-version> – vergleicht $PTERO_DIR mit dem Originalstand dieser Version
    # (app resources routes config database public; ohne .env, storage, vendor, node_modules, bootstrap/cache,
    # public/assets, public/build, .blueprint, *.rej/*.orig und bei installierter Übersetzung resources/lang/de).
    # Setzt GD_FOREIGN_FILES (Zeilen "M pfad" geändert, "A pfad" neu, "D pfad" gelöscht – nur die eigenen Änderungen),
    # GD_FOREIGN_COUNT, GD_FOREIGN_VERSION, GD_REFERENCE_DIR, GD_FOREIGN_BLUEPRINT (true/false), GD_BLUEPRINT_EXTENSIONS,
    # GD_BLUEPRINT_FILES (Zeilen im selben Format) und GD_BLUEPRINT_FILE_COUNT.
    # Blueprint schreibt beim Anwenden Kerndateien des Panels um und wendet sich nach jedem Update ohnehin erneut an.
    # Ist Blueprint installiert, werden die Abweichungen deshalb geteilt:
    #   (1) Blueprint-Dateien: Pfad unter app/BlueprintFramework/, routes/blueprint.php, resources/views/blueprint/,
    #       resources/scripts/blueprint/, public/extensions/, public/assets/extensions/, .blueprint/, blueprint.sh,
    #       database/migrations/*blueprint*, oder bei geänderten/neuen Dateien ein Inhalt mit "blueprint" (grep -qi)
    #   (2) alles übrige = echte eigene Änderungen (GD_FOREIGN_FILES)
    # Rückgabe: 0 = keine eigenen Änderungen (nach dem Herausrechnen), 1 = eigene Änderungen, 2 = Prüfung nicht möglich
    # (z. B. Download). Ohne Blueprint bleibt alles beim Alten.
    # Hinweis für gd_autoupdate_panel (lib/autoupdate.sh, wertet nur den Rückgabewert aus): Ein Panel mit installiertem
    # Blueprint und nur Blueprint-Abweichungen liefert jetzt 0 statt 1. Der Timer überspringt es dadurch nicht mehr
    # fälschlich, sondern aktualisiert es wie jedes andere Panel ohne eigene Änderungen.
    local version="$1" ref ex a b nref line kind path is_bp own=() bp=()
    GD_FOREIGN_FILES=""
    GD_FOREIGN_COUNT=0
    GD_FOREIGN_VERSION=""
    GD_FOREIGN_BLUEPRINT=false
    GD_BLUEPRINT_EXTENSIONS=""
    GD_BLUEPRINT_FILES=""
    GD_BLUEPRINT_FILE_COUNT=0
    if [ -z "$version" ] || [ ! -f "$PTERO_DIR/artisan" ]; then
        gd_log "Prüfung auf eigene Änderungen nicht möglich: Version oder Panel-Ordner unbekannt"
        return 2
    fi
    ref="$(gd_panel_reference_cache "$version")"
    if ! gd_panel_reference_tree "$version" "$ref"; then
        gd_log "Prüfung auf eigene Änderungen nicht möglich: Referenzstand von v${version} nicht verfügbar"
        return 2
    fi
    ex="$(gd_panel_change_exclude)"
    a="$GD_TMP/referenz-hashes.txt"
    b="$GD_TMP/panel-hashes.txt"
    gd_panel_hashes "$ref" "$ex" > "$a"
    gd_panel_hashes "$PTERO_DIR" "$ex" > "$b"
    nref="$(wc -l < "$a")"
    if [ "${nref:-0}" -lt 100 ]; then
        gd_log "Prüfung auf eigene Änderungen nicht möglich: Referenzstand unvollständig ($nref Dateien)"
        rm -f "$a" "$b"
        return 2
    fi
    # Zeile = 64 Zeichen Prüfsumme, 2 Leerzeichen, Pfad
    GD_FOREIGN_FILES="$(awk '
        NR == FNR { r[substr($0, 67)] = substr($0, 1, 64); next }
        { p = substr($0, 67)
          if (!(p in r)) print "A " p
          else { if (r[p] != substr($0, 1, 64)) print "M " p; delete r[p] } }
        END { for (p in r) print "D " p }' "$a" "$b" | LC_ALL=C sort -k2)"
    rm -f "$a" "$b"
    GD_FOREIGN_VERSION="$version"
    gd_panel_need blueprint gd_blueprint_installed
    if gd_blueprint_installed; then
        GD_FOREIGN_BLUEPRINT=true
        GD_BLUEPRINT_EXTENSIONS="$(gd_blueprint_extensions)"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            kind="${line%% *}"
            path="${line#? }"
            is_bp=false
            case "$path" in
                app/BlueprintFramework/*|routes/blueprint.php|resources/views/blueprint/*|resources/scripts/blueprint/*|public/extensions/*|public/assets/extensions/*|.blueprint/*|blueprint.sh|database/migrations/*blueprint*)
                    is_bp=true ;;
                *)
                    if [ "$kind" != D ] && grep -qi -- blueprint "$PTERO_DIR/$path" 2>/dev/null; then is_bp=true; fi ;;
            esac
            if [ "$is_bp" = true ]; then bp+=("$line"); else own+=("$line"); fi
        done <<< "$GD_FOREIGN_FILES"
        GD_BLUEPRINT_FILE_COUNT=${#bp[@]}
        # shellcheck disable=SC2034  # Ergebnisvariable, für Aufrufer und Protokoll bestimmt
        [ "$GD_BLUEPRINT_FILE_COUNT" -gt 0 ] && GD_BLUEPRINT_FILES="$(printf '%s\n' "${bp[@]}")"
        GD_FOREIGN_FILES=""
        [ ${#own[@]} -gt 0 ] && GD_FOREIGN_FILES="$(printf '%s\n' "${own[@]}")"
    fi
    GD_FOREIGN_COUNT=0
    [ -n "$GD_FOREIGN_FILES" ] && GD_FOREIGN_COUNT="$(wc -l <<< "$GD_FOREIGN_FILES")"
    gd_log "Prüfung auf eigene Änderungen (v${version}): ${GD_FOREIGN_COUNT} eigene Datei(en)$( [ "$GD_FOREIGN_BLUEPRINT" = true ] && echo ", Blueprint ist installiert (${GD_BLUEPRINT_FILE_COUNT} Dateien, wird nach dem Update neu angewendet)")"
    [ -n "$GD_FOREIGN_FILES" ] && printf '%s\n' "$GD_FOREIGN_FILES" | head -n 200 >> "$GD_LOG"
    [ "$GD_FOREIGN_COUNT" -eq 0 ]
}

# shellcheck disable=SC2034  # Ergebnisvariablen werden von Aufrufern gelesen
gd_panel_custom_save() {
    # gd_panel_custom_save <version> – sichert die fremden Änderungen als Patch
    #   /var/backups/germandactyl/eigene-aenderungen-<version>-<datum>.patch (Rechte 600) und als Kopie der geänderten und
    #   neuen Dateien in .../eigene-aenderungen-<version>-<datum>/ (Rechte 700). Grundlage ist GD_FOREIGN_FILES
    #   (gd_panel_detect_changes); fehlt die Liste für diese Version, wird sie erzeugt. Setzt GD_CUSTOM_PATCH und
    #   GD_CUSTOM_FILES_DIR (leer, wenn es nichts zu sichern gibt). Rückgabe 0 = gesichert oder nichts zu sichern, 1 = Fehler.
    local version="$1" ref stamp patch dest work rc line kind path pe pr left right
    GD_CUSTOM_PATCH=""
    GD_CUSTOM_FILES_DIR=""
    if [ "${GD_FOREIGN_VERSION:-}" != "$version" ]; then
        gd_panel_detect_changes "$version"
        rc=$?
        [ $rc -eq 2 ] && { echo "Die eigenen Änderungen konnten nicht ermittelt werden."; return 1; }
    fi
    [ -n "$GD_FOREIGN_FILES" ] || return 0
    ref="${GD_REFERENCE_DIR:-$(gd_panel_reference_cache "$version")}"
    stamp="$(date +%Y%m%d-%H%M%S)"
    patch="$GD_BACKUP_CUSTOM_ROOT/eigene-aenderungen-${version}-${stamp}.patch"
    dest="$GD_BACKUP_CUSTOM_ROOT/eigene-aenderungen-${version}-${stamp}"
    work="$GD_TMP/eigene-aenderungen.$$"
    rm -rf "$work"
    mkdir -p "$GD_BACKUP_CUSTOM_ROOT" "$work/a" "$work/b" "$dest" || return 1
    chmod 700 "$GD_BACKUP_CUSTOM_ROOT" "$dest" "$work"
    # Nur die gelisteten Pfade: links der Originalstand (geändert, gelöscht), rechts der aktuelle Stand (geändert, neu)
    awk '$1 == "M" || $1 == "D" { print substr($0, 3) }' <<< "$GD_FOREIGN_FILES" > "$work/original.liste"
    awk '$1 == "M" || $1 == "A" { print substr($0, 3) }' <<< "$GD_FOREIGN_FILES" > "$work/aktuell.liste"
    if [ -s "$work/original.liste" ]; then
        tar -C "$ref" -cf - -T "$work/original.liste" | tar -C "$work/a" -xf - || { rm -rf "$work" "$dest"; return 1; }
    fi
    if [ -s "$work/aktuell.liste" ]; then
        tar -C "$PTERO_DIR" -cf - -T "$work/aktuell.liste" | tar -C "$work/b" -xf - || { rm -rf "$work" "$dest"; return 1; }
    fi
    # Je Datei ein Diff (git diff --no-index): Bei neuen/gelöschten Dateien setzt git die Verzeichnisnamen a/b unterschiedlich
    # in die Kopfzeilen – sie werden danach einheitlich auf a/<pfad> und b/<pfad> gesetzt
    : > "$work/roh.patch"
    while IFS= read -r line; do
        kind="${line%% *}"
        path="${line#? }"
        pe="$(sed -E 's/[][\\.*^$\/#|+?(){}]/\\&/g' <<< "$path")"
        pr="$(sed -E 's/[\\&#]/\\&/g' <<< "$path")"
        case "$kind" in
            M) left="a/$path"; right="b/$path" ;;
            A) left=/dev/null; right="b/$path" ;;
            D) left="a/$path"; right=/dev/null ;;
            *) continue ;;
        esac
        ( cd "$work" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -c core.quotepath=off diff --no-index \
            --binary --no-color --no-ext-diff -- "$left" "$right" ) \
            | sed -E "/^(diff --git |--- |\+\+\+ )/ { s#(^| )a/[ab]/${pe}#\1a/${pr}#g; s#(^| )b/[ab]/${pe}#\1b/${pr}#g }" >> "$work/roh.patch"
    done <<< "$GD_FOREIGN_FILES"
    if [ ! -s "$work/roh.patch" ]; then
        echo "Der Patch mit den eigenen Änderungen konnte nicht erstellt werden."
        rm -rf "$work" "$dest"
        return 1
    fi
    ( umask 077; cp "$work/roh.patch" "$patch" ) || { rm -rf "$work" "$dest"; return 1; }
    chmod 600 "$patch"
    cp -a "$work/b/." "$dest/" || { rm -rf "$work" "$dest" "$patch"; return 1; }
    chmod 700 "$dest"
    rm -rf "$work"
    GD_CUSTOM_PATCH="$patch"
    GD_CUSTOM_FILES_DIR="$dest"
    gd_log "Eigene Änderungen gesichert: ${GD_FOREIGN_COUNT} Datei(en) – Patch: $patch, Kopie: $dest"
    return 0
}

# shellcheck disable=SC2034  # Ergebnisvariablen werden von Aufrufern gelesen
gd_panel_custom_reapply() {
    # gd_panel_custom_reapply <patchdatei> – wendet den mit gd_panel_custom_save gesicherten Patch im Panel an.
    # Dateien einzeln: Ist eine Änderung schon enthalten (z. B. von Blueprint oder der Übersetzung neu erzeugt, oder die
    # neue Version hat sie übernommen), wird sie übersprungen. Sonst "git apply --reject" (innerhalb eines Git-Repos zuerst
    # --3way; ohne Repo hat --3way keine Grundlage und scheitert). Rejects werden nach
    # /var/backups/germandactyl/rejects-eigene-<datum>/ verschoben (GD_CUSTOM_REJECT_DIR); eine Meldung steht in GD_WARNINGS
    # und im Log. GD_CUSTOM_NEEDS_BUILD=true, wenn Quelltext der Oberfläche (resources/scripts) angewendet wurde.
    # Rückgabe: 0 = vollständig, 1 = teilweise, 2 = gar nicht.
    local patch="$1" stamp rej_dir paths p out rc in_repo=false list n
    local ok=0 already=0 partial=() failed=() applied=() rejected=() before after
    GD_CUSTOM_REJECT_DIR=""
    GD_CUSTOM_NEEDS_BUILD=false
    [ -s "$patch" ] || { echo "Die Patch-Datei fehlt oder ist leer: $patch"; return 2; }
    cd "$PTERO_DIR" || return 2
    paths="$(git apply --numstat "$patch" 2>/dev/null | cut -f3-)"
    [ -n "$paths" ] || { echo "Der Patch enthält keine Dateien oder ist nicht lesbar."; return 2; }
    stamp="$(date +%Y%m%d-%H%M%S)"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_repo=true
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if git apply --reverse --check --include="$p" "$patch" >/dev/null 2>&1; then
            already=$((already + 1))
            continue
        fi
        if $in_repo && git apply --3way --whitespace=nowarn --include="$p" "$patch" >/dev/null 2>&1; then
            ok=$((ok + 1)); applied+=("$p")
            continue
        fi
        rm -f "$p.rej"
        before="$(sha256sum "$p" 2>/dev/null)"
        out="$(git apply --reject --whitespace=nowarn -v --include="$p" "$patch" 2>&1)"
        rc=$?
        echo "$out"
        [ -f "$p.rej" ] && rejected+=("$p")
        after="$(sha256sum "$p" 2>/dev/null)"
        if [ $rc -eq 0 ]; then
            ok=$((ok + 1)); applied+=("$p")
        elif [ "$before" != "$after" ]; then
            partial+=("$p")      # einzelne Teile angewendet, der Rest liegt als Reject vor
        else
            failed+=("$p")       # Datei unverändert
        fi
    done <<< "$paths"
    # Rejects (nicht angewendete Teile) einsammeln, mit Verzeichnisstruktur zur Nacharbeit
    rej_dir="$GD_BACKUP_CUSTOM_ROOT/rejects-eigene-${stamp}"
    for p in "${rejected[@]}"; do
        mkdir -p "$rej_dir/$(dirname "$p")" && mv -f "$p.rej" "$rej_dir/$p.rej" && GD_CUSTOM_REJECT_DIR="$rej_dir"
    done
    [ -n "$GD_CUSTOM_REJECT_DIR" ] && chmod 700 "$GD_BACKUP_CUSTOM_ROOT" "$rej_dir"
    for p in "${applied[@]}" "${partial[@]}"; do
        case "$p" in resources/scripts/*) GD_CUSTOM_NEEDS_BUILD=true ;; esac
    done
    GD_CUSTOM_APPLIED=$((ok + already))
    gd_log "Eigene Änderungen wieder angewendet: ${ok} angewendet, ${already} bereits enthalten, ${#partial[@]} teilweise, ${#failed[@]} nicht"
    if [ ${#partial[@]} -eq 0 ] && [ ${#failed[@]} -eq 0 ]; then
        return 0
    fi
    list="$(printf '%s\n' "${partial[@]}" "${failed[@]}" | grep . | sort -u)"
    n="$(wc -l <<< "$list")"
    gd_log "Nicht vollständig übernommen:"
    printf '%s\n' "$list" >> "$GD_LOG"
    list="$(head -n 5 <<< "$list" | paste -sd, - | sed 's/,/, /g')"
    [ "$n" -gt 5 ] && list+=" und $((n - 5)) weitere"
    GD_WARNINGS="${GD_WARNINGS:+$GD_WARNINGS\n}⚠ Eigene Änderungen konnten nicht vollständig übernommen werden: ${list}."
    if [ $((ok + already)) -gt 0 ] || [ ${#partial[@]} -gt 0 ]; then
        return 1
    fi
    return 2
}

# shellcheck disable=SC2034  # Ergebnisvariablen werden von Aufrufern gelesen
gd_panel_custom_reapply_step() {
    # Schritt im Update: eigene Änderungen wieder anwenden, Zwischenspeicher leeren, ggf. Oberfläche neu bauen.
    # Gibt immer 0 zurück – Teilergebnisse stehen in GD_WARNINGS, das Update selbst soll daran nicht scheitern.
    gd_panel_custom_reapply "$GD_CUSTOM_PATCH"
    GD_CUSTOM_REAPPLY_RC=$?
    gd_panel_permissions
    if [ "${GD_CUSTOM_NEEDS_BUILD:-false}" = true ]; then
        echo "Eigene Änderungen am Oberflächen-Quelltext: Oberfläche wird neu gebaut..."
        if ! { gd_install_node && gd_panel_build; }; then
            GD_WARNINGS="${GD_WARNINGS:+$GD_WARNINGS\n}⚠ Die Oberfläche konnte nach dem Wiederanwenden deiner Änderungen nicht neu gebaut werden (Details im Log)."
        fi
    fi
    ( cd "$PTERO_DIR" && php artisan view:clear && php artisan optimize:clear ) || true
    return 0
}

gd_panel_tools_ensure() {
    # git (Patch/Vergleich), tar/unzip/curl (Panel, Blueprint) – nur nachinstallieren, was fehlt
    local miss=() c
    for c in git tar unzip curl; do
        command -v "$c" >/dev/null 2>&1 || miss+=("$c")
    done
    [ ${#miss[@]} -eq 0 ] && return 0
    gd_apt_update
    gd_apt_install "${miss[@]}"
}

gd_panel_maintenance_on() {
    # Wartungsmodus einschalten (ein Fehler hier ist nicht fatal, z. B. bei kaputtem Panel)
    (cd "$PTERO_DIR" && php artisan down) || true
    return 0
}

gd_panel_update_record() {
    # gd_panel_update_record ok|fehler – Ergebnis des letzten Updates (liest u. a. die Statuszeile/MOTD)
    gd_conf_set LAST_UPDATE_RESULT "$1"
    gd_conf_set LAST_UPDATE_TIME "$(date '+%F %T')"
}

gd_panel_update_backup() {
    # Sicherung (Dateien + Datenbank) vor dem Update nach $GD_BACKUP_PANEL/vor-update-<version>-<datum>.tar.gz.
    # Setzt GD_UPDATE_BACKUP_FILE und LAST_UPDATE_BACKUP. Rückgabe 1, wenn die Sicherung nicht gelingt.
    local target need avail size
    GD_UPDATE_BACKUP_FILE=""
    if [ ! -f "$PTERO_DIR/artisan" ]; then
        echo "Kein Panel unter $PTERO_DIR vorhanden – es gibt nichts zu sichern."
        return 0
    fi
    gd_panel_need backup gd_backup_panel_create
    gd_backup_prepare
    # Platz grob prüfen: das Archiv ist komprimiert, daher reicht die Hälfte der Panel-Größe plus Reserve für die Datenbank
    size="$(du -sk --exclude=node_modules "$PTERO_DIR" 2>/dev/null | cut -f1)"
    need=$(( ${size:-0} / 2 + 102400 ))
    avail="$(df -Pk "$GD_BACKUP_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "$avail" ] && [ "$avail" -lt "$need" ]; then
        echo "Zu wenig Speicherplatz für die Sicherung in $GD_BACKUP_ROOT (frei: $((avail / 1024)) MB, benötigt: etwa $((need / 1024)) MB)."
        return 1
    fi
    target="$GD_BACKUP_PANEL/vor-update-${GD_PANEL_VERSION}-$(date +%Y%m%d-%H%M%S).tar.gz"
    if ! gd_backup_panel_create "$target" false; then
        echo "Die Sicherung vor dem Update ist fehlgeschlagen (Details im Log)."
        return 1
    fi
    GD_UPDATE_BACKUP_FILE="$target"
    gd_conf_set LAST_UPDATE_BACKUP "$target"
    echo "Sicherung vor dem Update: $target"
}

gd_panel_update_custom_save() {
    # Eigene Änderungen vor dem Update sichern (nur bei GD_UPDATE_REAPPLY=true). Die Liste wird hier neu ermittelt:
    # zwischen Rückfrage und Update können Minuten liegen. Ist die Prüfung nicht möglich, bricht das Update ab,
    # solange noch nichts verändert ist.
    local rc
    GD_CUSTOM_PATCH=""
    [ "${GD_UPDATE_REAPPLY:-false}" = true ] || return 0
    if [ -z "${GD_UPDATE_FROM_VERSION:-}" ]; then
        echo "Die installierte Version ist unbekannt – eigene Änderungen lassen sich nicht sichern."
        return 1
    fi
    gd_panel_detect_changes "$GD_UPDATE_FROM_VERSION"
    rc=$?
    if [ $rc -eq 2 ]; then
        echo "Die Prüfung auf eigene Änderungen war nicht möglich – das Update wird nicht gestartet."
        return 1
    fi
    [ $rc -eq 1 ] || { echo "Keine eigenen Änderungen gefunden."; return 0; }
    gd_panel_custom_save "$GD_UPDATE_FROM_VERSION"
}

gd_panel_update_steps() {
    # Erwartet GD_PANEL_VERSION und GD_APPLY_PATCH. Dialogfrei (auch für den automatischen Betrieb nutzbar).
    # Steuervariablen:
    #   GD_UPDATE_REAPPLY=true        fremde Änderungen vorher sichern und nachher wieder anwenden (Standard: false)
    #   GD_UPDATE_BACKUP=false        Sicherung vor dem Update weglassen (Standard: true)
    #   GD_UPDATE_AUTO_ROLLBACK=true  nach einem Fehler nach dem Entpacken die Sicherung automatisch zurückspielen
    # Ergebnis: GD_UPDATE_BACKUP_FILE, GD_CUSTOM_PATCH, GD_CUSTOM_REJECT_DIR, GD_WARNINGS sowie die Einstellungen
    # PANEL_VERSION, LAST_UPDATE_RESULT (ok|fehler), LAST_UPDATE_TIME und LAST_UPDATE_BACKUP.
    local current
    GD_UPDATE_PHASE=vor_entpacken
    GD_UPDATE_BACKUP_FILE=""
    GD_UPDATE_ROLLED_BACK=false
    GD_CUSTOM_PATCH=""
    GD_CUSTOM_REJECT_DIR=""
    GD_FAIL_HINT=""
    GD_UPDATE_FROM_VERSION="$(gd_panel_installed_version)"
    # Scheitert ein Schritt, räumt gd_panel_update_cleanup auf (vor dem Entpacken: Wartungsmodus beenden, danach:
    # Panel nicht freigeben, sondern Sicherung zurückspielen bzw. Hinweis setzen)
    GD_FAIL_CLEANUP=gd_panel_update_cleanup
    gd_panel_need blueprint gd_blueprint_installed
    gd_step 2 "Benötigte Werkzeuge (git, tar, unzip, curl) werden geprüft..." gd_panel_tools_ensure
    current="$(gd_php_current)"
    if [ -z "$current" ] || ! gd_version_ge "$current" "8.2"; then
        gd_step 5 "PHP wird von ${current:-unbekannt} auf ${GD_PHP_VERSION} aktualisiert..." gd_php_migrate
    fi
    # Herunterladen und prüfen, solange das Panel noch läuft: ein Netzwerkfehler legt es so nicht lahm
    gd_step 8 "Pterodactyl Panel v${GD_PANEL_VERSION} wird heruntergeladen..." gd_panel_fetch "$GD_PANEL_VERSION"
    if [ "${GD_UPDATE_BACKUP:-true}" != "false" ]; then
        gd_step 12 "Sicherung (Dateien + Datenbank) wird erstellt..." gd_panel_update_backup
    else
        gd_log "Sicherung vor dem Update ist ausgeschaltet (GD_UPDATE_BACKUP=false)."
    fi
    if [ "${GD_UPDATE_REAPPLY:-false}" = true ]; then
        gd_step 16 "Eigene Änderungen am Panel werden gesichert..." gd_panel_update_custom_save
    fi
    gd_step 18 "Panel wird in den Wartungsmodus versetzt..." gd_panel_maintenance_on
    # Ab jetzt ist das Panel verändert: ein Fehler lässt es im Wartungsmodus
    GD_UPDATE_PHASE=nach_entpacken
    gd_step 20 "Panel-Dateien v${GD_PANEL_VERSION} werden entpackt..." gd_panel_extract "$GD_PANEL_VERSION"
    gd_step 35 "Composer wird aktualisiert..." bash -c "composer self-update --2 >/dev/null 2>&1 || true"
    gd_step 40 "Composer-Abhängigkeiten werden installiert..." gd_panel_composer
    gd_step 55 "Zwischenspeicher werden geleert..." bash -c "cd '$PTERO_DIR' && php artisan view:clear && php artisan config:clear"
    gd_step 60 "Datenbank wird aktualisiert..." bash -c "cd '$PTERO_DIR' && php artisan migrate --seed --force"
    gd_step 65 "Berechtigungen werden gesetzt..." gd_panel_permissions
    gd_step_optional 66 "Cronjob wird geprüft..." "Der Cronjob des Panels konnte nicht als Benutzer www-data eingerichtet werden (Zeitpläne laufen sonst nicht)." gd_panel_cron
    gd_step 68 "Hintergrunddienste werden neu gestartet..." bash -c "cd '$PTERO_DIR' && php artisan queue:restart && systemctl restart pteroq"
    # Blueprint wird durch das Update teilweise überschrieben und mit der gespeicherten Version erneut angewendet
    # (eine neuere Version nur über Blueprint → Aktualisieren). blueprint.sh beendet den Wartungsmodus selbst.
    if gd_blueprint_installed; then
        gd_blueprint_install_step 69
        gd_step 69 "Panel bleibt im Wartungsmodus..." gd_panel_maintenance_on
    fi
    if [ "$GD_APPLY_PATCH" = "true" ]; then
        gd_germandactyl_steps 70
    fi
    if [ "${GD_UPDATE_REAPPLY:-false}" = true ] && [ -n "$GD_CUSTOM_PATCH" ]; then
        gd_step 85 "Eigene Änderungen werden wieder angewendet..." gd_panel_custom_reapply_step
    fi
    gd_step 95 "Panel wird wieder freigegeben..." bash -c "cd '$PTERO_DIR' && php artisan up"
    GD_FAIL_CLEANUP=""
    GD_UPDATE_PHASE=fertig
    gd_conf_set PANEL_VERSION "$GD_PANEL_VERSION"
    gd_panel_update_record ok
}

# shellcheck disable=SC2034  # Ergebnisvariablen werden von Aufrufern gelesen
gd_panel_update_cleanup() {
    # Aufräumen nach einem fehlgeschlagenen Update-Schritt (von gd_fail aufgerufen). Danach zeigt gd_fail GD_FAIL_HINT an.
    local file="${GD_UPDATE_BACKUP_FILE:-}"
    gd_panel_update_record fehler
    if [ "${GD_UPDATE_PHASE:-}" = nach_entpacken ]; then
        # Das Panel ist halb aktualisiert: nicht öffentlich schalten
        if [ -n "$file" ] && [ -f "$file" ] && [ "${GD_UPDATE_AUTO_ROLLBACK:-false}" = true ]; then
            gd_log "Das Update ist fehlgeschlagen – das Panel wird automatisch aus der Sicherung $file wiederhergestellt."
            gd_panel_need backup gd_backup_panel_restore
            if gd_backup_panel_restore "$file" >> "$GD_LOG" 2>&1; then
                gd_log "Wiederherstellung erfolgreich: ${GD_RESTORE_INFO:-}"
                GD_UPDATE_ROLLED_BACK=true
                GD_FAIL_HINT="Das Panel wurde automatisch auf den Stand vor dem Update zurückgesetzt (Sicherung: $file)."
            else
                gd_log "Wiederherstellung fehlgeschlagen: ${GD_RESTORE_INFO:-unbekannt}"
                GD_FAIL_HINT="Die automatische Wiederherstellung ist fehlgeschlagen (${GD_RESTORE_INFO:-unbekannt}). Das Panel bleibt im Wartungsmodus. Sicherung vor dem Update: $file – über Backups → Panel wiederherstellen einspielen."
            fi
        elif [ -n "$file" ] && [ -f "$file" ]; then
            GD_FAIL_HINT="Das Panel bleibt im Wartungsmodus. Sicherung vor dem Update: $file – über Backups → Panel wiederherstellen einspielen."
        else
            GD_FAIL_HINT="Das Panel bleibt im Wartungsmodus, weil das Update unvollständig ist. Es wurde keine Sicherung vor dem Update erstellt. Starte das Update erneut (Problembehandlung → Panel reparieren)."
        fi
    else
        # Vor dem Entpacken ist das Panel unverändert
        (cd "$PTERO_DIR" && php artisan up) >> "$GD_LOG" 2>&1
    fi
    declare -F gd_build_swap_off >/dev/null && gd_build_swap_off >> "$GD_LOG" 2>&1
    return 0
}

gd_panel_update_changes_dialog() {
    # gd_panel_update_changes_dialog <installierte-version> – roter Warndialog zu eigenen Änderungen (GD_FOREIGN_FILES)
    # und Auswahl, wie damit umgegangen wird. Blueprint-Dateien stehen nicht in der Liste, sondern nur als Zusatzzeile
    # (GD_BLUEPRINT_FILE_COUNT). Setzt GD_UPDATE_REAPPLY. Rückgabe 1 = Abbruch.
    # Ohne eigene Änderungen (nur Blueprint) wird dieser Dialog nicht gezeigt; dann kommt der Hinweis in den normalen
    # Bestätigungsdialog von gd_panel_update.
    local installed="$1" shown rest text choice lines
    shown="$(head -n 8 <<< "$GD_FOREIGN_FILES" | awk '{ k = $1; sub(/^. /, ""); print "  " (k == "M" ? "geändert" : (k == "A" ? "neu      " : "gelöscht ")) "  " $0 }')"
    text="Im Panel (v${installed}) weichen ${GD_FOREIGN_COUNT} Datei(en) vom Original ab:\n\n${shown}"
    if [ "$GD_FOREIGN_COUNT" -gt 8 ]; then
        rest=$((GD_FOREIGN_COUNT - 8))
        text+="\n  … und ${rest} weitere"
    fi
    if [ "${GD_FOREIGN_BLUEPRINT:-false}" = true ] && [ "${GD_BLUEPRINT_FILE_COUNT:-0}" -gt 0 ]; then
        text+="\n\nBlueprint ist installiert (${GD_BLUEPRINT_FILE_COUNT} Dateien) und wird nach dem Update automatisch neu angewendet."
        if [ -n "$GD_BLUEPRINT_EXTENSIONS" ]; then
            text+="\nErweiterungen: $(head -n 10 <<< "$GD_BLUEPRINT_EXTENSIONS" | paste -sd, - | sed 's/,/, /g')"
        fi
    fi
    text+="\n\nEin Update überschreibt diese Dateien."
    lines=$(( 11 + $(printf '%b' "$text" | fold -s -w 70 | wc -l) ))
    [ "$lines" -gt 26 ] && lines=26
    gd_warn_colors_on
    gd_whip --title "⚠ Eigene Änderungen am Panel erkannt" --scrolltext --msgbox "$text" "$lines" 78
    gd_warn_colors_off
    choice="$(gd_whip --title "Wie soll das Update mit den Änderungen umgehen?" --menu "Update von v${installed} auf v${GD_PANEL_VERSION}.\nDas Panel ist dabei einige Minuten nicht erreichbar. Vor dem Update wird automatisch eine Sicherung (Dateien + Datenbank) erstellt." 16 78 3 \
        "1" "Änderungen sichern und nach dem Update wieder anwenden (empfohlen)" \
        "2" "Ohne Übernahme (Änderungen gehen verloren, bleiben im Backup)" \
        "3" "Abbrechen" 3>&1 1>&2 2>&3)" || return 1
    case "$choice" in
        1) GD_UPDATE_REAPPLY=true ;;
        2) GD_UPDATE_REAPPLY=false ;;
        *) return 1 ;;
    esac
    return 0
}

gd_panel_yellow_on() {
    [ "${GD_HEADLESS:-}" = 1 ] && return 0
    GD_OLD_NEWT_COLORS_Y="${NEWT_COLORS:-}"
    export NEWT_COLORS='
    root=,yellow
    window=black,yellow
    border=black,yellow
    title=black,yellow
    textbox=black,yellow
    button=black,white
    actbutton=white,black
    compactbutton=black,yellow
    '
}

gd_panel_yellow_off() {
    [ "${GD_HEADLESS:-}" = 1 ] && return 0
    export NEWT_COLORS="${GD_OLD_NEWT_COLORS_Y:-}"
}

gd_panel_update() {
    # Interaktive Aktualisierung/Reparatur inklusive GermanDactyl
    local installed rc=0 text lines
    installed="$(gd_panel_installed_version)"
    GD_WARNINGS=""
    GD_UPDATE_REAPPLY=false
    GD_UPDATE_BACKUP=true
    GD_UPDATE_AUTO_ROLLBACK=false
    GD_FOREIGN_FILES=""
    GD_FOREIGN_COUNT=0
    GD_FOREIGN_VERSION=""
    GD_CUSTOM_REJECT_DIR=""
    GD_CUSTOM_PATCH=""
    gd_choose_panel_version || return 1
    # Downgrade-Schutz: Eine ältere Version würde die Datenbank-Struktur nicht zurückführen und das Panel beschädigen.
    # Dieselbe Version ist erlaubt (Reparatur).
    if [ -n "$installed" ] && [ "$installed" != "$GD_PANEL_VERSION" ] && gd_version_ge "$installed" "$GD_PANEL_VERSION"; then
        gd_msg "Downgrade nicht möglich" "Installiert ist v${installed}, ausgewählt wurde die ältere Version v${GD_PANEL_VERSION}.\n\nEin Wechsel auf eine ältere Panel-Version wird nicht unterstützt, da die Datenbank nicht zurückgeführt werden kann und das Panel dadurch beschädigt würde.\n\nWähle die installierte oder eine neuere Version." 15 74
        return 1
    fi
    # Vergleich mit dem Originalstand der installierten Version: erkennt Themes, Addons und eigene Anpassungen
    if [ -n "$installed" ]; then
        gd_whip --title "Panel prüfen" --infobox "Das Panel wird auf eigene Änderungen geprüft.\n\nBeim ersten Mal wird dafür die Originalversion v${installed} geladen..." 9 70
        gd_panel_detect_changes "$installed" >> "$GD_LOG" 2>&1
        rc=$?
    fi
    text="Installiert: v${installed:-unbekannt}\nZiel: v${GD_PANEL_VERSION} $( [ "$GD_APPLY_PATCH" = "true" ] && echo '(mit deutscher Übersetzung)' || echo '(Englisch)')\n\nDas Panel ist während der Aktualisierung einige Minuten nicht erreichbar. Änderungen an Dateien des Panels (Themes/Erweiterungen) werden dabei überschrieben.\n\nVor dem Update wird automatisch eine Sicherung (Dateien + Datenbank) erstellt.\n\nMöchtest du fortfahren?"
    [ "${GD_BLUEPRINT_FILE_COUNT:-0}" -gt 0 ] && text+="\n\nBlueprint ist installiert (${GD_BLUEPRINT_FILE_COUNT} Dateien) und wird nach dem Update automatisch neu angewendet."
    case "$rc" in
        1) gd_panel_update_changes_dialog "$installed" || return 1 ;;
        2)
            gd_panel_yellow_on
            gd_whip --title "⚠ Prüfung nicht möglich" --defaultno --yesno "Prüfung auf eigene Änderungen nicht möglich (Download fehlgeschlagen) – trotzdem fortfahren?\n\nEigene Änderungen an Dateien des Panels würden beim Update überschrieben. Vor dem Update wird automatisch eine Sicherung (Dateien + Datenbank) erstellt." 12 74
            rc=$?
            gd_panel_yellow_off
            [ "$rc" -eq 0 ] || return 1 ;;
        *) gd_yesno "↑ Panel aktualisieren" "$text" 18 78 || return 1 ;;
    esac
    gd_gauge_open "↑ Panel wird aktualisiert" "Aktualisierung wird vorbereitet..."
    gd_panel_update_steps
    gd_progress 100 "Aktualisierung abgeschlossen."
    gd_gauge_close
    text="Das Panel wurde auf v${GD_PANEL_VERSION} aktualisiert$(gd_blueprint_installed && echo ', Blueprint wurde erneut angewendet').\n\nFalls dein Browser noch die alte Oberfläche anzeigt, lade die Seite mit Strg + F5 neu."
    [ -n "${GD_UPDATE_BACKUP_FILE:-}" ] && text+="\n\nSicherung vor dem Update:\n${GD_UPDATE_BACKUP_FILE}"
    [ -n "${GD_WARNINGS:-}" ] && text+="\n\n${GD_WARNINGS}"
    if [ -n "${GD_CUSTOM_REJECT_DIR:-}" ]; then
        text+="\n\nNicht übernommene Teile deiner Änderungen:\n${GD_CUSTOM_REJECT_DIR}"
        [ -n "${GD_CUSTOM_PATCH:-}" ] && text+="\nGesicherter Patch: ${GD_CUSTOM_PATCH}"
    fi
    lines=$(( 8 + $(printf '%b' "$text" | fold -s -w 66 | wc -l) ))
    [ "$lines" -gt 24 ] && lines=24
    gd_whip --title "✔ Aktualisierung abgeschlossen" --scrolltext --msgbox "$text" "$lines" 70
}
