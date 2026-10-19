#!/bin/bash
# Pfad: lib/wings.sh
# Installation von Docker und Wings. Liegt das Panel auf demselben Server, wird Wings vollautomatisch
# eingerichtet: Location, Node, config.yml und Ports (Allocations) – ohne Handarbeit im Panel.
# Benötigt lib/common.sh (und für die Zertifikate lib/security.sh).

WINGS_BIN="/usr/local/bin/wings"
WINGS_CONFIG="/etc/pterodactyl/config.yml"
GD_DEFAULT_PORT_RANGE="25565-25600"

# ---------------------------------------------------------------------------
# Docker und Wings
# ---------------------------------------------------------------------------
gd_docker_install() {
    if command -v docker >/dev/null 2>&1; then
        echo "Docker ist bereits installiert: $(docker --version)"
        # Docker per Snap oder podman-docker hat keine docker.service – Wings (Requires=docker.service) startet dann nicht
        if ! systemctl cat docker.service >/dev/null 2>&1; then
            echo "Es gibt keinen Dienst docker.service (Docker per Snap oder podman?). Wings benötigt Docker aus dem offiziellen Paket (docker-ce oder docker.io)."
            return 1
        fi
        systemctl enable --now docker
        return 0
    fi
    gd_os_detect
    # Eine vorhandene Docker-Quelle (anderer Dateiname/Schlüssel) weiterverwenden – zwei Einträge mit
    # unterschiedlichem "signed-by" legen apt mit "Conflicting values set for option Signed-By" lahm
    if ! grep -rlsq 'download\.docker\.com' /etc/apt/sources.list /etc/apt/sources.list.d/; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${GD_OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc || return 1
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${GD_OS_ID} ${GD_OS_CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list
    fi
    gd_apt_update
    # gd_apt_update verschluckt Fehler: Liefert die frisch eingerichtete Docker-Quelle keine Pakete (z. B. weil es für
    # die Version des Systems noch kein Repository gibt), hier eine klare Meldung statt "Unable to locate package"
    if ! gd_apt_has_candidate docker-ce; then
        echo "Paketquelle für Docker (${GD_OS_CODENAME}) liefert keine Pakete – apt-get update prüfen"
        return 1
    fi
    gd_apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    systemctl enable --now docker
}

gd_wings_fetch() {
    # gd_wings_fetch <url> <ziel> [version] – Wings herunterladen, prüfen und installieren. Mit Angabe einer Version
    # muss das Programm genau diese Version melden ("wings version").
    # Wings veröffentlicht keine Prüfsummen-Datei; daher wird geprüft, dass ein vollständiges,
    # auf dieser Architektur lauffähiges Programm angekommen ist (statt z. B. einer HTML-Fehlerseite).
    # Download direkt neben das Ziel: /tmp ist auf gehärteten Servern oft "noexec", dann ließe sich
    # das Programm dort nicht testweise starten
    local url="$1" dest="$2" want="${3:-}" tmp size
    mkdir -p "$(dirname "$dest")"
    tmp="$(dirname "$dest")/.wings-download.$$"
    rm -f "$tmp"
    gd_curl "$url" -o "$tmp" \
        || { rm -f "$tmp"; echo "Download fehlgeschlagen: $url"; return 1; }
    size="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"
    if [ "$size" -lt 5000000 ] || [ "$(head -c 4 "$tmp" | od -An -c | tr -d ' ')" != "177ELF" ]; then
        rm -f "$tmp"
        echo "Die heruntergeladene Datei ist kein gültiges Wings-Programm (${size} Bytes)."
        return 1
    fi
    chmod 0755 "$tmp"
    # "wings version" gibt es seit Wings 1.0 (ein Flag "--version" gibt es nicht); "--help" als Rückfallebene
    if ! timeout 20 "$tmp" version >/dev/null 2>&1 && ! timeout 20 "$tmp" --help >/dev/null 2>&1; then
        rm -f "$tmp"
        echo "Das heruntergeladene Wings-Programm lässt sich auf diesem Server nicht ausführen (Architektur: $(gd_arch))."
        return 1
    fi
    # Wurde eine bestimmte Version angefordert, muss die Datei sie auch melden (sonst z. B. falsches Release-Asset)
    if [ -n "$want" ] && ! timeout 20 "$tmp" version 2>/dev/null | grep -qF "$want"; then
        rm -f "$tmp"
        echo "Das heruntergeladene Wings-Programm meldet nicht die angeforderte Version v${want}."
        return 1
    fi
    # mv auf demselben Dateisystem ersetzt atomar – funktioniert auch, während Wings läuft (Update)
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    echo "Installiert: Wings v$("$dest" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -n1)"
    return 0
}

gd_wings_binary() {
    # gd_wings_binary [version] – lädt Wings (ohne Angabe: die neueste Version) und ersetzt $WINGS_BIN. Setzt
    # GD_WINGS_BINARY_VERSION. WINGS_VERSION in setup.conf wird hier bewusst NICHT geschrieben: erst der Aufrufer
    # speichert sie, nachdem Wings mit der neuen Datei erfolgreich gestartet ist.
    local arch version="${1:-}" requested="${1:-}"
    GD_WINGS_BINARY_VERSION=""
    arch="$(gd_arch)"
    case "$arch" in amd64|arm64) ;; *) echo "Nicht unterstützte Architektur: $arch"; return 1 ;; esac
    if [ -z "$version" ]; then
        version="$(gd_latest_release pterodactyl/wings)" || { echo "Die aktuelle Wings-Version konnte nicht ermittelt werden."; return 1; }
    fi
    mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes
    gd_wings_fetch "https://github.com/pterodactyl/wings/releases/download/v${version}/wings_linux_${arch}" "$WINGS_BIN" "$requested" || return 1
    GD_WINGS_BINARY_VERSION="$version"
}

gd_wings_service() {
    # Offizielle Service-Datei (https://pterodactyl.io/wings/1.0/installing.html)
    cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable wings
}

gd_nginx_webroot_for() {
    # gd_nginx_webroot_for <fqdn> – gibt den Webroot aus, wenn es für den FQDN bereits einen nginx-Server-Block von
    # GermanDactyl Setup gibt (Pterodactyl oder Pelican). Rückgabe 1, wenn nicht.
    local fqdn="$1" pair conf root
    for pair in "pterodactyl.conf:${PTERO_DIR}/public" "pelican.conf:${PELICAN_DIR:-/var/www/pelican}/public"; do
        conf="/etc/nginx/sites-available/${pair%%:*}"
        root="${pair#*:}"
        if [ -d "$root" ] && grep -qE "^[[:space:]]*server_name[[:space:]]+${fqdn//./\\.}[[:space:]]*;" "$conf" 2>/dev/null; then
            echo "$root"
            return 0
        fi
    done
    return 1
}

gd_nginx_foreign_block() {
    # gd_nginx_foreign_block <fqdn> – gibt es einen fremden nginx-Server-Block (nicht von GermanDactyl Setup) für den FQDN?
    local fqdn="$1"
    grep -RlsE "^[[:space:]]*server_name[[:space:]]+([^;]*[[:space:]])?${fqdn//./\\.}[[:space:];]" \
        /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null \
        | xargs -r -n1 readlink -f | grep -vE '/(germandactyl-acme|pterodactyl|pelican)\.conf$' | grep -q .
}

gd_acme_block_write() {
    # gd_acme_block_write <fqdn> – minimaler HTTP-Server-Block nur für die Zertifikatsprüfung (Webroot-Verfahren):
    # /.well-known/acme-challenge/ wird aus /var/www/letsencrypt bedient, alles andere ergibt 404. Weitere FQDNs
    # werden in dieselbe Datei aufgenommen.
    local fqdn="$1" f="/etc/nginx/sites-available/germandactyl-acme.conf" names
    names="$(sed -nE 's/^[[:space:]]*server_name[[:space:]]+([^;]+);.*/\1/p' "$f" 2>/dev/null | head -n1)"
    case " $names " in
        *" $fqdn "*) ;;
        *) names="${names:+$names }$fqdn" ;;
    esac
    mkdir -p /var/www/letsencrypt /etc/nginx/sites-available
    gd_nginx_backup germandactyl-acme.conf
    cat > "$f" <<ACME
# Angelegt von GermanDactyl Setup: nur für die Zertifikatsprüfung (Let's Encrypt, Webroot-Verfahren)
server {
    listen 80;
$(gd_has_ipv6 && echo "    listen [::]:80;")
    server_name ${names};
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        allow all;
    }
    location / {
        return 404;
    }
}
ACME
    gd_nginx_activate germandactyl-acme.conf
}

gd_acme_webroot_prepare() {
    # gd_acme_webroot_prepare <fqdn> – setzt GD_ACME_WEBROOT für den FQDN (nginx läuft). Gibt es für den FQDN schon
    # einen Server-Block des Panels, wird dessen Webroot genutzt, sonst wird ein minimaler Block angelegt.
    # Rückgabe 2: ein fremder Server-Block belegt den FQDN (Webroot unbekannt), 1: Fehler.
    local fqdn="$1" root
    GD_ACME_WEBROOT=""
    if root="$(gd_nginx_webroot_for "$fqdn")"; then
        GD_ACME_WEBROOT="$root"
        return 0
    fi
    gd_nginx_foreign_block "$fqdn" && return 2
    gd_acme_block_write "$fqdn" || return 1
    GD_ACME_WEBROOT="/var/www/letsencrypt"
}

gd_wings_certificate() {
    # gd_wings_certificate <fqdn> <email> – Zertifikat für die Wings-Domain. Ein vorhandenes Zertifikat bleibt nur,
    # wenn es noch mindestens 14 Tage gilt, zur Domain passt, nicht aus der Testumgebung stammt und das
    # Erneuerungsverfahren zum Server passt: Läuft nginx, scheitert "standalone" bei der Erneuerung (Port 80 belegt).
    # Dann wird nur die Erneuerung auf Webroot umgestellt (keine Neuausstellung, das zählt gegen das
    # Let's-Encrypt-Limit von 5 Duplikaten pro Woche). Benötigt lib/panel.sh (Zertifikatshilfen, nginx).
    local fqdn="$1" email="$2" cert conf auth method nginx_on=false force=() rc
    cert="/etc/letsencrypt/live/${fqdn}/fullchain.pem"
    conf="/etc/letsencrypt/renewal/${fqdn}.conf"
    method="${GD_SSL_METHOD:-$(gd_conf_get SSL_METHOD)}"
    # Panel hinter dem Cloudflare-Proxy (Token vorhanden): auch das Wings-Zertifikat per DNS-01 ausstellen.
    # Der FQDN von Wings muss trotzdem direkt erreichbar sein (DNS only), nur die Prüfung läuft über die DNS-API.
    if [ "$method" = "cloudflare" ] && [ -s "${GD_CF_INI:-/etc/letsencrypt/cloudflare.ini}" ]; then
        gd_certbot_dns_cloudflare "$fqdn" "$email"
        return
    fi
    command -v certbot >/dev/null 2>&1 || gd_apt_install certbot || return 1
    systemctl is-active --quiet nginx && nginx_on=true
    # Port 80 dauerhaft offen lassen, sonst scheitert die automatische Erneuerung später
    if gd_ufw_active; then ufw allow 80/tcp comment "HTTP (Zertifikate)" >/dev/null; fi
    if [ -f "$cert" ]; then
        if gd_cert_reusable "$fqdn"; then
            auth="$(gd_certbot_auth "$fqdn")"
            if ! $nginx_on || [ "$auth" != "standalone" ]; then
                echo "Zertifikat für ${fqdn} ist bereits vorhanden (noch ${GD_CERT_DAYS} Tage gültig, Verfahren: ${auth:-unbekannt})."
                return 0
            fi
            echo "Zertifikat für ${fqdn} ist noch ${GD_CERT_DAYS} Tage gültig, wurde aber per 'standalone' ausgestellt – nginx belegt Port 80, deshalb wird nur die Erneuerung auf Webroot umgestellt."
            gd_acme_webroot_prepare "$fqdn"
            if [ -n "$GD_ACME_WEBROOT" ] && gd_certbot_switch_auth "$fqdn" webroot "$GD_ACME_WEBROOT"; then
                return 0
            fi
            echo "Die Umstellung hat nicht funktioniert – das Zertifikat wird neu ausgestellt."
        else
            echo "Vorhandenes Zertifikat für ${fqdn} wird neu ausgestellt (${GD_CERT_REASON})."
        fi
        force=(--force-renewal)
    elif [ -e "$conf" ]; then
        # Reste eines gelöschten Zertifikats würden certbot blockieren
        certbot delete --cert-name "$fqdn" --non-interactive
    fi
    if $nginx_on; then
        gd_acme_webroot_prepare "$fqdn"
        rc=$?
        if [ $rc -eq 0 ]; then
            certbot certonly --webroot -w "$GD_ACME_WEBROOT" -d "$fqdn" --cert-name "$fqdn" "${force[@]}" \
                --email "$email" --agree-tos --no-eff-email --non-interactive
        elif [ $rc -eq 2 ]; then
            # Fremder Server-Block für den FQDN: Certbot muss ihn selbst finden (nginx-Plugin)
            certbot plugins 2>/dev/null | grep -q '^\* nginx' || gd_apt_install python3-certbot-nginx || return 1
            certbot certonly --nginx -d "$fqdn" --cert-name "$fqdn" "${force[@]}" \
                --email "$email" --agree-tos --no-eff-email --non-interactive
        else
            echo "Der nginx-Server-Block für die Zertifikatsprüfung konnte nicht angelegt werden."
            return 1
        fi
    else
        # Ohne Webserver: Certbot startet kurzzeitig einen eigenen auf Port 80 – der muss frei sein
        if ss -Hltn 'sport = :80' 2>/dev/null | grep -q .; then
            echo "Port 80 ist von einem anderen Programm belegt ($(ss -Hltnp 'sport = :80' 2>/dev/null | grep -oE '"[^"]+"' | head -n1))."
            echo "Let's Encrypt prüft die Domain ${fqdn} über Port 80 – das Zertifikat kann so nicht ausgestellt werden."
            echo "Beende das Programm, das Port 80 belegt, und starte die Einrichtung erneut."
            return 1
        fi
        certbot certonly --standalone -d "$fqdn" --cert-name "$fqdn" "${force[@]}" \
            --email "$email" --agree-tos --no-eff-email --non-interactive
    fi
}

gd_ask_wings_domain() {
    # gd_ask_wings_domain <panel-domain> "Text" – fragt eine eigene Domain für Wings ab und gibt sie aus.
    # Wings (Port 8080 und SFTP 2022) läuft nicht über den Cloudflare-Proxy – die Domain muss direkt auf den
    # Server zeigen ("DNS only"). Rückgabe 1 bei Abbruch.
    local fqdn
    while true; do
        fqdn="$(gd_ask_domain "⇄ Domain für Wings" "$2")" || return 1
        if gd_is_cloudflare_ip "$(gd_resolve_a "$fqdn" | head -n1)"; then
            gd_msg "⚠ Cloudflare-Proxy erkannt" "Die Domain ${fqdn} läuft über den Cloudflare-Proxy (orange Wolke). Wings (Port 8080) und SFTP (Port 2022) sind darüber nicht erreichbar.\n\nStelle den Eintrag in Cloudflare auf 'DNS only' (graue Wolke) oder wähle eine andere Domain." 13 76
            continue
        fi
        echo "$fqdn"
        return 0
    done
}

gd_wings_network_prepare() {
    # Wings legt sein Docker-Netzwerk immer mit IPv6 an. Auf Servern ohne IPv6 (z. B. ipv6.disable=1)
    # scheitert das ("Cannot read IPv6 setup for bridge"), und Wings startet nicht. Ein vorhandenes
    # Netzwerk gleichen Namens verwendet Wings weiter – deshalb hier vorab ein reines IPv4-Netzwerk anlegen.
    # gd_wings_network_prepare [config.yml] [netzwerkname] [bridge-name]
    local cfg="${1:-$WINGS_CONFIG}" name="${2:-pterodactyl_nw}" bridge="${3:-pterodactyl0}" subnet gateway prefix i
    command -v docker >/dev/null 2>&1 || return 0
    docker network inspect "$name" >/dev/null 2>&1 && return 0
    subnet="$(awk '/v4:/{f=1} f && $1=="subnet:" {print $2; exit}' "$cfg" 2>/dev/null | tr -d "'\"")"
    gateway="$(awk '/v4:/{f=1} f && $1=="gateway:" {print $2; exit}' "$cfg" 2>/dev/null | tr -d "'\"")"
    # Kollidiert das Subnetz (Standard 172.18.0.0/16) mit einem vorhandenen Docker-Netz (z. B. docker compose)
    # oder dem Servernetz, ein freies 172.x.0.0/16 wählen und in der config.yml eintragen
    prefix="$(cut -d. -f1-2 <<< "${subnet:-172.18.0.0/16}")"
    if gd_subnet_in_use "$prefix"; then
        for i in $(seq 19 31); do
            gd_subnet_in_use "172.$i" && continue
            echo "Subnetz ${prefix}.0.0/16 ist bereits belegt – Wings nutzt stattdessen 172.$i.0.0/16."
            sed -i -E "/(subnet|gateway|interface):/ s/${prefix//./\\.}\./172.$i./g" "$cfg"
            subnet="172.$i.0.0/16"; gateway="172.$i.0.1"
            break
        done
    fi
    gd_has_ipv6 && return 0
    echo "Server ohne IPv6: Docker-Netzwerk $name wird ohne IPv6 angelegt."
    docker network create --driver bridge --subnet "${subnet:-172.18.0.0/16}" --gateway "${gateway:-172.18.0.1}" \
        -o "com.docker.network.bridge.name=${bridge}" "$name"
}

gd_subnet_in_use() {
    # gd_subnet_in_use <a.b> – wird a.b.0.0/16 schon von Docker-Netzen, Routen oder Adressen verwendet?
    local p="${1//./\\.}\."
    { docker network inspect $(docker network ls -q 2>/dev/null) -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n'
      ip -4 route 2>/dev/null | awk '{print $1}'
      ip -4 -o addr 2>/dev/null | awk '{print $4}'; } | grep -qE "^$p"
}

gd_wings_start() {
    systemctl restart wings || return 1
    local i
    for i in $(seq 1 15); do
        systemctl is-active --quiet wings && return 0
        sleep 2
    done
    journalctl -u wings -n 30 --no-pager -o cat
    return 1
}

gd_wings_verify_external() {
    # gd_wings_verify_external <fqdn> <port> <header-datei> – zweiter Versuch ohne --resolve, also über DNS und die
    # öffentliche IP – so erreichen Panel-Besucher und das Panel Wings tatsächlich. Immer Rückgabe 0: Scheitert nur dieser
    # Weg (Firewall des Hosters, Portfreigabe; hinter NAT evtl. fehlendes Hairpin-NAT), steht eine Warnung in GD_WARNINGS.
    local fqdn="$1" port="$2" hdr="$3" code i warn
    for i in 1 2 3; do
        code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 10 \
            -H "@${hdr}" "https://${fqdn}:${port}/api/system")"
        echo "Wings-API über DNS/öffentliche IP antwortet mit HTTP $code"
        [ "$code" = "200" ] && return 0
        sleep 3
    done
    warn="Wings läuft, ist aber von außen auf Port ${port} nicht erreichbar – prüfe die Firewall deines Hosters (Hetzner/OVH/Oracle Cloud) und Portfreigaben für ${port} und 2022."
    gd_log "WARNUNG: $warn"
    case "${GD_WARNINGS:-}" in
        *"$warn"*) ;;
        *) GD_WARNINGS="${GD_WARNINGS:+$GD_WARNINGS\n}⚠ $warn" ;;
    esac
    return 0
}

gd_wings_verify() {
    # Fragt die Wings-API mit dem Node-Token ab – entspricht dem "grünen Herz" im Panel. Die Prüfung läuft zuerst nur
    # über 127.0.0.1 (--resolve), danach zusätzlich von außen (gd_wings_verify_external, nicht fatal).
    # gd_wings_verify <fqdn> [config.yml] – Standard: Pterodactyl-Wings
    local fqdn="$1" cfg="${2:-$WINGS_CONFIG}" token port code i hdr="$GD_TMP/wings-auth.hdr"
    token="$(awk '$1=="token:"{print $2; exit}' "$cfg" | tr -d "'\"")"
    port="$(awk '/^api:/{a=1} a && $1=="port:"{print $2; exit}' "$cfg")"
    port="${port:-8080}"
    # Den Token als Header aus einer privaten Datei übergeben ("-H @datei"): als curl-Argument stünde er in der
    # Prozessliste und wäre für alle lokalen Benutzer sichtbar
    ( umask 077; printf 'Authorization: Bearer %s\n' "$token" > "$hdr" )
    for i in $(seq 1 10); do
        code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${fqdn}:${port}:127.0.0.1" \
            -H "@${hdr}" "https://${fqdn}:${port}/api/system")"
        echo "Wings-API antwortet mit HTTP $code"
        if [ "$code" = "200" ]; then
            gd_wings_verify_external "$fqdn" "$port" "$hdr"
            rm -f "$hdr"
            return 0
        fi
        sleep 3
    done
    rm -f "$hdr"
    return 1
}

# ---------------------------------------------------------------------------
# Automatische Einrichtung im lokalen Panel
# ---------------------------------------------------------------------------
gd_panel_env() {
    grep -E "^$1=" "$PTERO_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | sed -E "s/^[\"'](.*)[\"']$/\\1/"
}

gd_panel_sql() {
    # SQL in der Panel-Datenbank ausführen – mit den Zugangsdaten des Panels (funktioniert auch,
    # wenn root ein Passwort hat). Auf root über den unix_socket wird nur zurückgegriffen, wenn die
    # Anmeldung mit den Panel-Zugangsdaten scheitert (Zugriff verweigert / keine Verbindung) – ein
    # Fehler in der SQL-Anweisung selbst wird gemeldet und nicht mit root-Rechten wiederholt.
    local db user pass host port cnf out err rc client
    db="$(gd_panel_env DB_DATABASE)"; user="$(gd_panel_env DB_USERNAME)"; pass="$(gd_panel_env DB_PASSWORD)"
    host="$(gd_panel_env DB_HOST)"; port="$(gd_panel_env DB_PORT)"
    if [ -n "$user" ] && [ -n "$pass" ]; then
        cnf="$GD_TMP/panel-db.cnf"; out="$GD_TMP/panel-sql.out"; err="$GD_TMP/panel-sql.err"
        ( umask 077; printf '[client]\nuser="%s"\npassword="%s"\nhost="%s"\nport="%s"\n' \
            "$user" "${pass//\"/\\\"}" "${host:-127.0.0.1}" "${port:-3306}" > "$cnf" )
        client=mysql; command -v mariadb >/dev/null 2>&1 && client=mariadb
        "$client" --defaults-extra-file="$cnf" -N -D "${db:-panel}" -e "$1" > "$out" 2> "$err"
        rc=$?
        rm -f "$cnf"
        if [ $rc -eq 0 ]; then
            cat "$out"; rm -f "$out" "$err"
            return 0
        fi
        # Fehlercodes: 1045 = Access denied (Benutzer/Passwort), 1044 = kein Zugriff auf die Datenbank,
        # 1130 = Host nicht erlaubt, 2002/2003 = keine Verbindung zum Server/Socket, 2013 = Verbindung verloren
        if ! grep -qE "ERROR (1044|1045|1130|2002|2003|2013)|Access denied|Can't connect" "$err"; then
            cat "$err" >&2; rm -f "$out" "$err"
            return $rc
        fi
        rm -f "$out" "$err"
    fi
    gd_mysql -N -D "${db:-panel}" -e "$1"
}

gd_wings_location() {
    # Vorhandene Location "DE" wiederverwenden, sonst anlegen. Gibt die ID aus.
    local id
    id="$(gd_panel_sql "SELECT id FROM locations WHERE short='DE' ORDER BY id LIMIT 1;")"
    if [ -z "$id" ]; then
        gd_artisan_www p:location:make --short=DE --long="Deutschland" >&2 || return 1
        id="$(gd_panel_sql "SELECT id FROM locations WHERE short='DE' ORDER BY id LIMIT 1;")"
    fi
    [ -n "$id" ] && echo "$id"
}

gd_wings_node_resources() {
    # Setzt GD_NODE_MEMORY und GD_NODE_DISK (MB) anhand der Serverausstattung
    local mem disk
    mem="$(LC_ALL=C free -m | awk '/^Mem:/{print $2}')"
    [ -d "$PTERO_DIR" ] && mem=$((mem - 1024))   # Reserve für Panel, Datenbank und System
    [ "$mem" -lt 1024 ] && mem=1024
    mkdir -p /var/lib/pterodactyl
    disk="$(df -Pm /var/lib/pterodactyl | awk 'NR==2{print $4}')"
    disk=$((disk * 90 / 100))
    [ "$disk" -lt 5120 ] && disk=5120
    GD_NODE_MEMORY="$mem"
    GD_NODE_DISK="$disk"
}

gd_wings_node_create() {
    # gd_wings_node_create <fqdn> – legt die Node an und setzt GD_NODE_ID
    local fqdn="$1" location out existing
    existing="$(gd_panel_sql "SELECT id FROM nodes WHERE fqdn='${fqdn}' ORDER BY id LIMIT 1;")"
    if [ -n "$existing" ]; then
        echo "Es existiert bereits eine Node mit ${fqdn} (ID ${existing}), sie wird verwendet."
        GD_NODE_ID="$existing"
        return 0
    fi
    location="$(gd_wings_location)" || return 1
    gd_wings_node_resources
    out="$(gd_artisan_www p:node:make --no-interaction \
        --name="Node-$(hostname -s)" --description="Automatisch eingerichtet von GermanDactyl Setup" \
        --locationId="$location" --fqdn="$fqdn" --public=1 --scheme=https --proxy=0 --maintenance=0 \
        --maxMemory="$GD_NODE_MEMORY" --overallocateMemory=0 --maxDisk="$GD_NODE_DISK" --overallocateDisk=0 \
        --uploadSize=100 --daemonListeningPort=8080 --daemonSFTPPort=2022 \
        --daemonBase=/var/lib/pterodactyl/volumes)" || { echo "$out"; return 1; }
    echo "$out"
    GD_NODE_ID="$(grep -oiE '(id of|id) [0-9]+' <<< "$out" | grep -oE '[0-9]+' | tail -n1)"
    [ -z "$GD_NODE_ID" ] && GD_NODE_ID="$(gd_panel_sql "SELECT id FROM nodes WHERE fqdn='${fqdn}' ORDER BY id DESC LIMIT 1;")"
    [ -n "$GD_NODE_ID" ]
}

gd_wings_config_write() {
    mkdir -p /etc/pterodactyl
    gd_artisan_www p:node:configuration "$GD_NODE_ID" --format=yaml > "$GD_TMP/config.yml" || return 1
    grep -q '^token:' "$GD_TMP/config.yml" || { cat "$GD_TMP/config.yml"; return 1; }
    [ -f "$WINGS_CONFIG" ] && cp -p "$WINGS_CONFIG" "${WINGS_CONFIG}.bak-$(date +%Y%m%d%H%M%S)"
    install -m 600 "$GD_TMP/config.yml" "$WINGS_CONFIG"
}

gd_allocation_ip() {
    # Setzt GD_ALLOC_IP und GD_ALLOC_ALIAS: lokale IP (bei NAT mit öffentlicher IP als Alias)
    GD_ALLOC_IP="$(gd_local_ip)"; GD_ALLOC_ALIAS=""
    if [ -n "$GD_ALLOC_IP" ] && gd_is_private_ip "$GD_ALLOC_IP"; then
        # Server hinter NAT: Docker bindet an die lokale IP, Spieler verbinden sich über die öffentliche
        GD_ALLOC_ALIAS="$(gd_public_ip)"
    fi
    [ -z "$GD_ALLOC_IP" ] && GD_ALLOC_IP="$(gd_public_ip)"
    # Reiner IPv6-Server
    [ -z "$GD_ALLOC_IP" ] && GD_ALLOC_IP="$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    [ -n "$GD_ALLOC_IP" ]
}

gd_allocations_add() {
    # gd_allocations_add <node-id> <ip> <alias oder leer> <port oder bereich> – Ports im Panel anlegen
    local node="$1" ip="$2" alias_ip="$3" range="$4" a b port values="" alias_php="null" out count
    # ip und alias_ip stammen teils aus Netzwerkabfragen bzw. der Panel-Datenbank und landen unten in PHP-Code
    # und SQL: vorher strikt prüfen (nur IP-Zeichen bzw. Hostname-Zeichen, keine Anführungszeichen o. Ä.)
    [[ "$node" =~ ^[0-9]+$ ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f.:]{1,45}$ ]] || return 1
    [[ "$range" =~ ^[0-9]{1,5}(-[0-9]{1,5})?$ ]] || return 1
    [[ -z "$alias_ip" || "$alias_ip" =~ ^[A-Za-z0-9.:_-]{1,191}$ ]] || alias_ip=""
    [ -n "$alias_ip" ] && alias_php="'${alias_ip}'"
    # Ausgabe samt Fehlermeldungen aufnehmen: scheitert dieser Weg, steht der Grund im Log
    out="$(gd_artisan_www tinker --execute="app(\\Pterodactyl\\Services\\Allocations\\AssignmentService::class)->handle(\\Pterodactyl\\Models\\Node::findOrFail(${node}), ['allocation_ip' => '${ip}', 'allocation_alias' => ${alias_php}, 'allocation_ports' => ['${range}']]); echo 'OK';" 2>&1)"
    if grep -q 'OK' <<< "$out"; then
        echo "Ports ${range} für ${ip} angelegt (über das Panel)."
    else
        gd_log "Ports ${range} konnten nicht über das Panel (tinker) angelegt werden – Rückfall auf die Datenbank. Ausgabe von tinker:"
        printf '%s\n' "$out" | tail -n 20 | cut -c1-300 >> "$GD_LOG"
        # Rückfallebene: direkt in die Datenbank schreiben (doppelte Einträge werden ignoriert)
        a="${range%-*}"; b="${range#*-}"
        for port in $(seq "$a" "$b"); do
            values+="(${node},'${ip}',$( [ -n "$alias_ip" ] && echo "'${alias_ip}'" || echo NULL ),${port},NOW(),NOW()),"
        done
        gd_panel_sql "INSERT IGNORE INTO allocations (node_id, ip, ip_alias, port, created_at, updated_at) VALUES ${values%,};" || return 1
        # Kontrolle: Es müssen jetzt Ports für die Node existieren (ein stiller Fehler ließe sonst eine Node ohne Ports zurück)
        count="$(gd_panel_sql "SELECT COUNT(*) FROM allocations WHERE node_id=${node};")"
        if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
            echo "Die Ports konnten nicht angelegt werden: Für die Node ${node} gibt es keine Allocations."
            return 1
        fi
        echo "Ports ${range} für ${ip} angelegt (direkt in der Datenbank, ${count} Ports für die Node vorhanden)."
    fi
}

gd_wings_allocations() {
    # gd_wings_allocations <portbereich> – Ports der neu angelegten Node freigeben (Installation)
    gd_allocation_ip || { echo "IP-Adresse konnte nicht ermittelt werden."; return 1; }
    gd_allocations_add "$GD_NODE_ID" "$GD_ALLOC_IP" "$GD_ALLOC_ALIAS" "$1" || return 1
    gd_conf_set WINGS_PORT_RANGE "$1"
}

# ---------------------------------------------------------------------------
# Abläufe
# ---------------------------------------------------------------------------
gd_wings_local_steps() {
    # Wings auf demselben Server wie das Panel – vollautomatisch.
    # Erwartet: GD_WINGS_FQDN, GD_EMAIL, GD_PORT_RANGE
    # gd_wings_local_steps [start-prozent] [spanne] – die Schritte werden auf die Spanne verteilt
    local p="${1:-72}" span="${2:-17}"
    gd_step "$p" "Docker wird installiert..." gd_docker_install
    gd_step $((p + 6 * span / 17)) "Wings wird heruntergeladen..." gd_wings_binary
    gd_step $((p + 8 * span / 17)) "Wings-Dienst wird eingerichtet..." gd_wings_service
    gd_step $((p + 9 * span / 17)) "SSL-Zertifikat für Wings wird geprüft..." gd_wings_certificate "$GD_WINGS_FQDN" "$GD_EMAIL"
    gd_step $((p + 10 * span / 17)) "Node wird im Panel angelegt..." gd_wings_node_create "$GD_WINGS_FQDN"
    gd_step $((p + 12 * span / 17)) "Wings-Konfiguration wird geschrieben..." gd_wings_config_write
    gd_step $((p + 13 * span / 17)) "Ports ${GD_PORT_RANGE} werden für Gameserver freigegeben..." gd_wings_allocations "$GD_PORT_RANGE"
    gd_step $((p + 14 * span / 17)) "Docker-Netzwerk für Gameserver wird vorbereitet..." gd_wings_network_prepare
    gd_step $((p + 15 * span / 17)) "Wings wird gestartet..." gd_wings_start
    gd_step $((p + 17 * span / 17)) "Verbindung zwischen Panel und Wings wird geprüft..." gd_wings_verify "$GD_WINGS_FQDN"
    gd_conf_set WINGS_FQDN "$GD_WINGS_FQDN"
    gd_conf_set WINGS_NODE_ID "$GD_NODE_ID"
    # Erst jetzt, nach erfolgreichem Start und bestandener Prüfung, gilt die Version als installiert
    [ -n "${GD_WINGS_BINARY_VERSION:-}" ] && gd_conf_set WINGS_VERSION "$GD_WINGS_BINARY_VERSION"
    return 0
}

gd_wings_remote_steps() {
    # Wings auf einem eigenen Server (Panel liegt woanders). Erwartet: GD_WINGS_FQDN, GD_EMAIL
    local p="${1:-5}"
    gd_step "$p"        "Paketquellen werden aktualisiert..." gd_apt_update
    gd_step $((p + 5))  "Benötigte Pakete werden installiert..." gd_apt_install curl ca-certificates gnupg certbot
    gd_step $((p + 15)) "Docker wird installiert..." gd_docker_install
    gd_step $((p + 40)) "Wings wird heruntergeladen..." gd_wings_binary
    gd_step $((p + 50)) "Wings-Dienst wird eingerichtet..." gd_wings_service
    gd_step $((p + 55)) "SSL-Zertifikat für Wings wird angefordert..." gd_wings_certificate "$GD_WINGS_FQDN" "$GD_EMAIL"
    gd_step $((p + 60)) "Automatische Zertifikatserneuerung wird eingerichtet..." gd_certbot_hook
    gd_conf_set WINGS_FQDN "$GD_WINGS_FQDN"
}

gd_wings_configure_remote() {
    # Den im Panel erzeugten Befehl "wings configure ..." abfragen und ausführen (ersetzt das Bearbeiten der config.yml)
    local cmd url token node
    gd_msg "⇄ Wings mit dem Panel verbinden" "So verbindest du Wings mit deinem Panel:\n\n1. Öffne im Panel: Admin → Nodes → Create New\n   FQDN: ${GD_WINGS_FQDN}, 'Communicate Over SSL' aktivieren.\n2. Öffne nach dem Anlegen den Reiter 'Configuration'.\n3. Klicke rechts auf 'Generate Token'.\n4. Kopiere den angezeigten Befehl und füge ihn im nächsten Fenster ein\n   (mit der rechten Maustaste bzw. Strg + Umschalt + V)." 18 78
    while true; do
        cmd="$(gd_input "⇄ Befehl einfügen" "Füge hier den Befehl aus dem Panel ein:" "" 10 78)" || return 1
        url="$(grep -oE -- '--panel-url +https?://[^ ]+' <<< "$cmd" | awk '{print $2}')"
        token="$(grep -oE -- '--token +[A-Za-z0-9._-]+' <<< "$cmd" | awk '{print $2}')"
        node="$(grep -oE -- '--node +[0-9]+' <<< "$cmd" | awk '{print $2}')"
        if [ -n "$url" ] && [ -n "$token" ] && [ -n "$node" ]; then
            break
        fi
        gd_msg "Befehl nicht erkannt" "Der eingefügte Text enthält nicht --panel-url, --token und --node. Bitte kopiere den kompletten Befehl erneut." 10 70
    done
    clear
    echo "Wings wird mit dem Panel verbunden..."
    if (cd /etc/pterodactyl && "$WINGS_BIN" configure --panel-url "$url" --token "$token" --node "$node" --override) >> "$GD_LOG" 2>&1 \
        && gd_wings_network_prepare >> "$GD_LOG" 2>&1 && gd_wings_start >> "$GD_LOG" 2>&1; then
        gd_conf_set WINGS_PANEL_URL "$url"
        # Wings läuft mit der neuen Datei: Version erst jetzt speichern
        [ -n "${GD_WINGS_BINARY_VERSION:-}" ] && gd_conf_set WINGS_VERSION "$GD_WINGS_BINARY_VERSION"
        return 0
    fi
    gd_msg "✖ Verbindung fehlgeschlagen" "Wings konnte nicht mit dem Panel verbunden werden.\n\nPrüfe, ob das Panel erreichbar ist und der Token noch gültig ist (er kann nur einmal verwendet werden).\n\nLog: $GD_LOG" 14 78
    return 1
}

# ---------------------------------------------------------------------------
# Wings aktualisieren
# ---------------------------------------------------------------------------
gd_wings_installed_version() {
    # Installierte Wings-Version aus "wings version", z. B. 1.11.13 (leer + Rückgabe 1, wenn nicht ermittelbar)
    local v
    [ -x "$WINGS_BIN" ] || return 1
    v="$(timeout 15 "$WINGS_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    [ -n "$v" ] || return 1
    echo "$v"
}

gd_wings_update_available() {
    # Gibt die neuere Wings-Version aus, falls es eine gibt. Rückgabe 1, wenn Wings aktuell ist oder eine der
    # Versionen nicht ermittelt werden kann.
    local installed latest
    installed="$(gd_wings_installed_version)" || return 1
    latest="$(gd_latest_release pterodactyl/wings)" || return 1
    [ -n "$latest" ] || return 1
    gd_version_ge "$installed" "$latest" && return 1
    echo "$latest"
}

# shellcheck disable=SC2034  # Ergebnisvariablen werden von Aufrufern gelesen
gd_wings_major_mismatch() {
    # gd_wings_major_mismatch <wings-version> – weicht die Major-Version von der des Panels ab? Das Panel ist die lokale
    # Installation, sonst die Version aus setup.conf (PANEL_VERSION). Rückgabe 0 = Abweichung (GD_WINGS_UPDATE_MESSAGE
    # beschreibt sie), 1 = passt oder Panel-Version unbekannt (z. B. Wings auf einem eigenen Server).
    local wv="$1" pv=""
    GD_WINGS_UPDATE_MESSAGE=""
    if [ -f "$PTERO_DIR/artisan" ] && declare -F gd_panel_installed_version >/dev/null; then
        pv="$(gd_panel_installed_version)"
    fi
    [ -n "$pv" ] || pv="$(gd_conf_get PANEL_VERSION)"
    GD_WINGS_PANEL_VERSION="$pv"
    [ -n "$pv" ] && [ -n "$wv" ] || return 1
    [ "${pv%%.*}" != "${wv%%.*}" ] || return 1
    GD_WINGS_UPDATE_MESSAGE="Wings v${wv} gehört zur Major-Version ${wv%%.*}, dein Panel (v${pv}) zur Major-Version ${pv%%.*}. Beide müssen dieselbe Major-Version haben – sonst kann sich Wings nicht mehr mit dem Panel verbinden."
    return 0
}

gd_wings_fqdn() {
    # FQDN der Wings-Node: aus setup.conf, sonst aus dem Zertifikatspfad in der config.yml
    local f
    f="$(gd_conf_get WINGS_FQDN)"
    [ -n "$f" ] || f="$(awk '$1=="cert:"{print $2; exit}' "$WINGS_CONFIG" 2>/dev/null | tr -d "'\"" | sed -nE 's#.*/live/([^/]+)/.*#\1#p')"
    echo "$f"
}

gd_wings_update_check() {
    # Funktionsprüfung nach einem Update: Dienst läuft stabil und – wenn eine config.yml vorhanden ist – die
    # Wings-API antwortet mit dem Node-Token (wie das grüne Herz im Panel)
    local fqdn ssl
    sleep 3
    systemctl is-active --quiet wings || return 1
    [ -f "$WINGS_CONFIG" ] || return 0
    fqdn="$(gd_wings_fqdn)"
    ssl="$(awk '/^[[:space:]]+ssl:/{s=1;next} s && $1=="enabled:"{print $2; exit}' "$WINGS_CONFIG" 2>/dev/null)"
    if [ -z "$fqdn" ] || [ "$ssl" = "false" ]; then
        echo "Die Wings-API wird nicht geprüft (FQDN unbekannt oder SSL in der config.yml aus) – nur der Dienst wird kontrolliert."
        sleep 5
        systemctl is-active --quiet wings
        return
    fi
    gd_wings_verify "$fqdn"
}

gd_wings_update_record() {
    # gd_wings_update_record ok|fehler
    gd_conf_set LAST_WINGS_UPDATE_RESULT "$1"
    gd_conf_set LAST_WINGS_UPDATE_TIME "$(date '+%F %T')"
}

gd_wings_update_rollback() {
    # gd_wings_update_rollback <grund> – bisherige Wings-Datei zurückspielen und Wings neu starten
    GD_WINGS_UPDATE_MESSAGE="$1"
    gd_log "Wings-Update fehlgeschlagen: $1"
    if [ -f "$WINGS_BIN.bak" ]; then
        gd_progress 90 "Die vorherige Wings-Version wird wiederhergestellt..."
        if cp -p "$WINGS_BIN.bak" "$WINGS_BIN.rollback" && mv -f "$WINGS_BIN.rollback" "$WINGS_BIN"; then
            if gd_wings_start >> "$GD_LOG" 2>&1; then
                gd_log "Die vorherige Wings-Version ist wiederhergestellt und läuft."
            else
                gd_log "Die vorherige Wings-Version ist wiederhergestellt, Wings startet aber nicht (journalctl -u wings)."
                GD_WINGS_UPDATE_MESSAGE="$1 Auch die vorherige Version startet nicht – siehe 'journalctl -u wings'."
            fi
        else
            rm -f "$WINGS_BIN.rollback"
            GD_WINGS_UPDATE_MESSAGE="$1 Die vorherige Version konnte nicht zurückgespielt werden (Sicherung: $WINGS_BIN.bak)."
        fi
    fi
    gd_wings_update_record fehler
}

# shellcheck disable=SC2034  # Ergebnisvariablen werden von Aufrufern gelesen
gd_wings_update_steps() {
    # Aktualisiert Wings auf die neueste Version, dialogfrei. Variablen:
    #   GD_WINGS_TARGET_VERSION   Zielversion (Standard: neueste)
    #   GD_WINGS_IGNORE_MAJOR     true = Abweichung der Major-Version zum Panel nicht beanstanden
    # Ergebnis: GD_WINGS_UPDATE_FROM, GD_WINGS_UPDATE_TO, GD_WINGS_UPDATE_MESSAGE und die Einstellungen WINGS_VERSION
    # (erst nach erfolgreichem Start), LAST_WINGS_UPDATE_RESULT (ok|fehler) und LAST_WINGS_UPDATE_TIME.
    # Rückgabe: 0 = aktualisiert, 1 = fehlgeschlagen (vorherige Version wiederhergestellt), 3 = Major-Version von Panel
    # und Wings weichen ab (nichts verändert, der Aufrufer entscheidet; mit GD_WINGS_IGNORE_MAJOR=true wiederholen).
    local target
    GD_WINGS_UPDATE_MESSAGE=""
    GD_WINGS_UPDATE_FROM="$(gd_wings_installed_version)"
    target="${GD_WINGS_TARGET_VERSION:-}"
    gd_progress 5 "Neueste Wings-Version wird ermittelt..."
    [ -n "$target" ] || target="$(gd_latest_release pterodactyl/wings)"
    GD_WINGS_UPDATE_TO="$target"
    if [ -z "$target" ]; then
        GD_WINGS_UPDATE_MESSAGE="Die aktuelle Wings-Version konnte nicht ermittelt werden (github.com erreichbar?)."
        gd_log "Wings-Update fehlgeschlagen: $GD_WINGS_UPDATE_MESSAGE"
        gd_wings_update_record fehler
        return 1
    fi
    if [ "${GD_WINGS_IGNORE_MAJOR:-false}" != true ] && gd_wings_major_mismatch "$target"; then
        gd_log "Wings-Update nicht ausgeführt: $GD_WINGS_UPDATE_MESSAGE"
        echo "$GD_WINGS_UPDATE_MESSAGE"
        return 3
    fi
    gd_progress 10 "Die aktuelle Wings-Datei wird gesichert..."
    rm -f "$WINGS_BIN.bak"
    if [ -f "$WINGS_BIN" ]; then
        cp -p "$WINGS_BIN" "$WINGS_BIN.bak" || {
            GD_WINGS_UPDATE_MESSAGE="Die aktuelle Wings-Datei konnte nicht gesichert werden (Speicherplatz?)."
            gd_log "Wings-Update fehlgeschlagen: $GD_WINGS_UPDATE_MESSAGE"
            gd_wings_update_record fehler
            return 1
        }
    fi
    gd_progress 20 "Wings v${target} wird heruntergeladen..."
    if ! gd_wings_binary "$target" >> "$GD_LOG" 2>&1; then
        # gd_wings_fetch ersetzt die Datei erst nach erfolgreicher Prüfung: die bisherige Version ist unverändert
        GD_WINGS_UPDATE_MESSAGE="Wings v${target} konnte nicht heruntergeladen werden. Die bisherige Version läuft unverändert weiter."
        gd_log "Wings-Update fehlgeschlagen: $GD_WINGS_UPDATE_MESSAGE"
        gd_wings_update_record fehler
        return 1
    fi
    gd_progress 60 "Wings wird neu gestartet..."
    if ! gd_wings_start >> "$GD_LOG" 2>&1; then
        gd_wings_update_rollback "Wings v${target} startet nicht. Die vorherige Version wurde wiederhergestellt."
        return 1
    fi
    gd_progress 80 "Wings wird geprüft..."
    if ! gd_wings_update_check >> "$GD_LOG" 2>&1; then
        gd_wings_update_rollback "Wings v${target} läuft, besteht aber die Funktionsprüfung nicht (Wings-API antwortet nicht). Die vorherige Version wurde wiederhergestellt."
        return 1
    fi
    gd_conf_set WINGS_VERSION "$target"
    gd_wings_update_record ok
    gd_log "Wings aktualisiert: ${GD_WINGS_UPDATE_FROM:-unbekannt} -> $target"
    return 0
}

gd_wings_update() {
    # Wings auf die neueste Version aktualisieren (interaktiv)
    local installed latest rc
    latest="$(gd_latest_release pterodactyl/wings)"
    if [ -z "$latest" ]; then
        gd_msg "Fehler" "Die aktuelle Wings-Version konnte nicht ermittelt werden. Prüfe die Internetverbindung (github.com)." 9 70
        return 1
    fi
    installed="$(gd_wings_installed_version)"
    if [ -n "$installed" ] && gd_version_ge "$installed" "$latest"; then
        gd_msg "✔ Wings ist aktuell" "Installiert ist Wings v${installed} – das ist die neueste Version." 8 64
        return 0
    fi
    gd_yesno "↑ Wings aktualisieren" "Installiert: v${installed:-unbekannt}\nNeu: v${latest}\n\nWings startet kurz neu, laufende Gameserver laufen weiter.\n\nVorher wird die aktuelle Datei gesichert; startet die neue Version nicht oder besteht sie die Prüfung nicht, wird sie automatisch zurückgespielt.\n\nMöchtest du fortfahren?" 17 74 || return 1
    GD_WINGS_TARGET_VERSION="$latest"
    GD_WINGS_IGNORE_MAJOR=false
    if gd_wings_major_mismatch "$latest"; then
        gd_warn_colors_on
        gd_whip --title "⚠ Panel und Wings passen nicht zusammen" --defaultno --yesno "${GD_WINGS_UPDATE_MESSAGE}\n\nMit dem Update verliert Wings sehr wahrscheinlich die Verbindung zum Panel – deine Gameserver lassen sich dann nicht mehr über das Panel steuern.\n\nEmpfehlung: Abbrechen und zuerst das Panel aktualisieren.\n\nTrotzdem aktualisieren?" 16 74
        rc=$?
        gd_warn_colors_off
        [ "$rc" -eq 0 ] || return 1
        GD_WINGS_IGNORE_MAJOR=true
    fi
    gd_gauge_open "↑ Wings wird aktualisiert" "Aktualisierung wird vorbereitet..."
    gd_wings_update_steps
    rc=$?
    if [ $rc -eq 0 ]; then
        gd_progress 100 "Fertig."
    fi
    gd_gauge_close
    GD_WINGS_IGNORE_MAJOR=false
    GD_WINGS_TARGET_VERSION=""
    if [ $rc -eq 0 ]; then
        gd_msg "✔ Wings aktualisiert" "Wings wurde auf v$(gd_conf_get WINGS_VERSION) aktualisiert und neu gestartet." 9 60
        return 0
    fi
    gd_msg "✖ Wings-Update fehlgeschlagen" "${GD_WINGS_UPDATE_MESSAGE:-Das Update ist fehlgeschlagen.}\n\nDetails: $GD_LOG" 13 74
    return 1
}

gd_swap_create() {
    # gd_swap_create <MB> – Swap-Datei anlegen und dauerhaft in /etc/fstab eintragen
    local size="$1" file="/swapfile" virt fstype
    [ -e "$file" ] && { echo "$file existiert bereits."; return 1; }
    virt="$(systemd-detect-virt -c 2>/dev/null)"
    case "$virt" in
        lxc|lxc-libvirt|openvz) echo "In einem ${virt}-Container kann kein eigener Swap angelegt werden (Sache des Hosts)."; return 1 ;;
    esac
    fstype="$(stat -f -c %T / 2>/dev/null)"
    if [ "$fstype" = "btrfs" ]; then
        # btrfs braucht eine Datei ohne Copy-on-Write
        btrfs filesystem mkswapfile --size "${size}m" "$file" || return 1
    else
        # Datei zuerst mit Rechten 600 anlegen: Eine Swap-Datei mit 644 könnte jeder lokale Benutzer lesen
        # (sie enthält Auszüge aus dem Arbeitsspeicher, z. B. Passwörter)
        install -m 600 /dev/null "$file" || return 1
        fallocate -l "${size}M" "$file" 2>/dev/null || dd if=/dev/zero of="$file" bs=1M count="$size" status=none || { rm -f "$file"; return 1; }
        mkswap "$file" || { rm -f "$file"; return 1; }
    fi
    chmod 600 "$file"
    if ! swapon "$file"; then
        # fallocate erzeugt auf manchen Dateisystemen Dateien "mit Löchern", die swapon ablehnt
        rm -f "$file"
        install -m 600 /dev/null "$file" \
            && dd if=/dev/zero of="$file" bs=1M count="$size" status=none && mkswap "$file" && swapon "$file" \
            || { rm -f "$file"; return 1; }
    fi
    grep -qE "^${file}[[:space:]]" /etc/fstab || echo "$file none swap sw 0 0" >> /etc/fstab
}

gd_swap_remove() {
    local file="/swapfile"
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$file"; then
        # Reicht der freie RAM nicht, scheitert swapoff – dann die (noch aktive) Datei nicht löschen
        swapoff "$file" || { echo "Swap konnte nicht deaktiviert werden (zu wenig freier Arbeitsspeicher?)."; return 1; }
    fi
    rm -f "$file"
    sed -i -E "\#^${file}[[:space:]]#d" /etc/fstab
}
