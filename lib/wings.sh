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
        systemctl enable --now docker
        return 0
    fi
    gd_os_detect
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${GD_OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc || return 1
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${GD_OS_ID} ${GD_OS_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    gd_apt update || return 1
    gd_apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    systemctl enable --now docker
}

gd_wings_binary() {
    local arch version
    arch="$(gd_arch)"
    case "$arch" in amd64|arm64) ;; *) echo "Nicht unterstützte Architektur: $arch"; return 1 ;; esac
    version="$(gd_latest_release pterodactyl/wings)" || { echo "Die aktuelle Wings-Version konnte nicht ermittelt werden."; return 1; }
    mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes
    curl -fL "https://github.com/pterodactyl/wings/releases/download/v${version}/wings_linux_${arch}" -o "$GD_TMP/wings" || return 1
    install -m 0755 "$GD_TMP/wings" "$WINGS_BIN" || return 1
    gd_conf_set WINGS_VERSION "$version"
    "$WINGS_BIN" --version
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
PIDFile=/var/run/wings/daemon.pid
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

gd_wings_certificate() {
    # gd_wings_certificate <fqdn> <email> – Zertifikat für die Wings-Domain, falls noch nicht vorhanden
    local fqdn="$1" email="$2"
    [ -f "/etc/letsencrypt/live/${fqdn}/fullchain.pem" ] && { echo "Zertifikat für ${fqdn} ist bereits vorhanden."; return 0; }
    command -v certbot >/dev/null 2>&1 || gd_apt_install certbot python3-certbot-nginx || return 1
    if systemctl is-active --quiet nginx; then
        certbot certonly --nginx -d "$fqdn" --email "$email" --agree-tos --no-eff-email --non-interactive
    else
        # Ohne Webserver: Certbot startet kurzzeitig einen eigenen auf Port 80
        certbot certonly --standalone -d "$fqdn" --email "$email" --agree-tos --no-eff-email --non-interactive
    fi
}

gd_wings_start() {
    systemctl restart wings || return 1
    local i
    for i in $(seq 1 15); do
        systemctl is-active --quiet wings && return 0
        sleep 2
    done
    journalctl -u wings -n 30 --no-pager
    return 1
}

gd_wings_verify() {
    # Fragt die Wings-API mit dem Node-Token ab – entspricht dem "grünen Herz" im Panel
    local fqdn="$1" token port code i
    token="$(awk '$1=="token:"{print $2; exit}' "$WINGS_CONFIG" | tr -d "'\"")"
    port="$(awk '/^api:/{a=1} a && $1=="port:"{print $2; exit}' "$WINGS_CONFIG")"
    port="${port:-8080}"
    for i in $(seq 1 10); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${fqdn}:${port}:127.0.0.1" \
            -H "Authorization: Bearer ${token}" "https://${fqdn}:${port}/api/system")"
        echo "Wings-API antwortet mit HTTP $code"
        [ "$code" = "200" ] && return 0
        sleep 3
    done
    return 1
}

# ---------------------------------------------------------------------------
# Automatische Einrichtung im lokalen Panel
# ---------------------------------------------------------------------------
gd_panel_env() {
    grep -E "^$1=" "$PTERO_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'
}

gd_panel_sql() {
    # SQL in der Panel-Datenbank ausführen (als root über den unix_socket)
    local db
    db="$(gd_panel_env DB_DATABASE)"
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
    mem="$(free -m | awk '/^Mem:/{print $2}')"
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
    GD_NODE_ID="$(grep -oE 'id of [0-9]+' <<< "$out" | grep -oE '[0-9]+' | tail -n1)"
    [ -z "$GD_NODE_ID" ] && GD_NODE_ID="$(gd_panel_sql "SELECT id FROM nodes WHERE fqdn='${fqdn}' ORDER BY id DESC LIMIT 1;")"
    [ -n "$GD_NODE_ID" ]
}

gd_wings_config_write() {
    mkdir -p /etc/pterodactyl
    gd_artisan_www p:node:configuration "$GD_NODE_ID" --format=yaml > "$GD_TMP/config.yml" || return 1
    grep -q '^token:' "$GD_TMP/config.yml" || { cat "$GD_TMP/config.yml"; return 1; }
    install -m 600 "$GD_TMP/config.yml" "$WINGS_CONFIG"
}

gd_wings_allocations() {
    # gd_wings_allocations <portbereich> – Ports für Gameserver im Panel freigeben
    local range="$1" ip alias_ip="" a b port values=""
    ip="$(gd_local_ip)"
    if [ -n "$ip" ] && gd_is_private_ip "$ip"; then
        # Server hinter NAT: Docker bindet an die lokale IP, Spieler verbinden sich über die öffentliche
        alias_ip="$(gd_public_ip)"
    fi
    [ -z "$ip" ] && ip="$(gd_public_ip)"
    [ -z "$ip" ] && { echo "IP-Adresse konnte nicht ermittelt werden."; return 1; }

    local alias_php="null"
    [ -n "$alias_ip" ] && alias_php="'${alias_ip}'"
    if gd_artisan_www tinker --execute="app(\\Pterodactyl\\Services\\Allocations\\AssignmentService::class)->handle(\\Pterodactyl\\Models\\Node::findOrFail(${GD_NODE_ID}), ['allocation_ip' => '${ip}', 'allocation_alias' => ${alias_php}, 'allocation_ports' => ['${range}']]); echo 'OK';" | grep -q 'OK'; then
        echo "Ports ${range} für ${ip} angelegt (über das Panel)."
    else
        # Rückfallebene: direkt in die Datenbank schreiben (doppelte Einträge werden ignoriert)
        a="${range%-*}"; b="${range#*-}"
        for port in $(seq "$a" "$b"); do
            values+="(${GD_NODE_ID},'${ip}',$( [ -n "$alias_ip" ] && echo "'${alias_ip}'" || echo NULL ),${port},NOW(),NOW()),"
        done
        gd_panel_sql "INSERT IGNORE INTO allocations (node_id, ip, ip_alias, port, created_at, updated_at) VALUES ${values%,};" || return 1
        echo "Ports ${range} für ${ip} angelegt (direkt in der Datenbank)."
    fi
    gd_conf_set WINGS_PORT_RANGE "$range"
}

# ---------------------------------------------------------------------------
# Abläufe
# ---------------------------------------------------------------------------
gd_wings_local_steps() {
    # Wings auf demselben Server wie das Panel – vollautomatisch.
    # Erwartet: GD_WINGS_FQDN, GD_EMAIL, GD_PORT_RANGE
    local p="${1:-72}"
    gd_step "$p"        "Docker wird installiert..." gd_docker_install
    gd_step $((p + 6))  "Wings wird heruntergeladen..." gd_wings_binary
    gd_step $((p + 8))  "Wings-Dienst wird eingerichtet..." gd_wings_service
    gd_step $((p + 9))  "SSL-Zertifikat für Wings wird geprüft..." gd_wings_certificate "$GD_WINGS_FQDN" "$GD_EMAIL"
    gd_step $((p + 10)) "Node wird im Panel angelegt..." gd_wings_node_create "$GD_WINGS_FQDN"
    gd_step $((p + 12)) "Wings-Konfiguration wird geschrieben..." gd_wings_config_write
    gd_step $((p + 13)) "Ports ${GD_PORT_RANGE} werden für Gameserver freigegeben..." gd_wings_allocations "$GD_PORT_RANGE"
    gd_step $((p + 15)) "Wings wird gestartet..." gd_wings_start
    gd_step $((p + 17)) "Verbindung zwischen Panel und Wings wird geprüft..." gd_wings_verify "$GD_WINGS_FQDN"
    gd_conf_set WINGS_FQDN "$GD_WINGS_FQDN"
    gd_conf_set WINGS_NODE_ID "$GD_NODE_ID"
}

gd_wings_remote_steps() {
    # Wings auf einem eigenen Server (Panel liegt woanders). Erwartet: GD_WINGS_FQDN, GD_EMAIL
    local p="${1:-5}"
    gd_step "$p"        "Paketquellen werden aktualisiert..." gd_apt update
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
    gd_msg "🔗 Wings mit dem Panel verbinden" "So verbindest du Wings mit deinem Panel:\n\n1. Öffne im Panel: Admin → Nodes → Create New\n   FQDN: ${GD_WINGS_FQDN}, 'Communicate Over SSL' aktivieren.\n2. Öffne nach dem Anlegen den Reiter 'Configuration'.\n3. Klicke rechts auf 'Generate Token'.\n4. Kopiere den angezeigten Befehl und füge ihn im nächsten Fenster ein\n   (mit der rechten Maustaste bzw. Strg + Umschalt + V)." 18 78
    while true; do
        cmd="$(gd_input "🔗 Befehl einfügen" "Füge hier den Befehl aus dem Panel ein:" "" 10 78)" || return 1
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
        && gd_wings_start >> "$GD_LOG" 2>&1; then
        gd_conf_set WINGS_PANEL_URL "$url"
        return 0
    fi
    gd_msg "❌ Verbindung fehlgeschlagen" "Wings konnte nicht mit dem Panel verbunden werden.\n\nPrüfe, ob das Panel erreichbar ist und der Token noch gültig ist (er kann nur einmal verwendet werden).\n\nLog: $GD_LOG" 14 78
    return 1
}

gd_wings_update() {
    # Wings auf die neueste Version aktualisieren
    gd_gauge_open "⬆️ Wings wird aktualisiert" "Aktualisierung wird vorbereitet..."
    gd_step 20 "Neueste Wings-Version wird heruntergeladen..." gd_wings_binary
    gd_step 80 "Wings wird neu gestartet..." gd_wings_start
    gd_progress 100 "Fertig."
    gd_gauge_close
    gd_msg "✅ Wings aktualisiert" "Wings wurde auf v$(gd_conf_get WINGS_VERSION) aktualisiert und neu gestartet." 9 60
}

gd_swap_create() {
    # gd_swap_create <MB> – Swap-Datei anlegen und dauerhaft in /etc/fstab eintragen
    local size="$1" file="/swapfile"
    [ -e "$file" ] && { echo "$file existiert bereits."; return 1; }
    fallocate -l "${size}M" "$file" 2>/dev/null || dd if=/dev/zero of="$file" bs=1M count="$size" status=none || return 1
    chmod 600 "$file"
    mkswap "$file" && swapon "$file" || { rm -f "$file"; return 1; }
    grep -q "^$file " /etc/fstab || echo "$file none swap sw 0 0" >> /etc/fstab
}

gd_swap_remove() {
    local file="/swapfile"
    swapoff "$file" 2>/dev/null
    rm -f "$file"
    sed -i "\#^$file #d" /etc/fstab
}
