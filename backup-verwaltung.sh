#!/bin/bash
# Pfad: backup-verwaltung.sh
# Backups des Panels (Dateien + Datenbank + .env) und der Gameserver (Wings-Volumes) erstellen,
# wiederherstellen und löschen. Ablage: /opt/pterodactyl/backups/{panel,server}

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
gd_source_lib backup
gd_source_lib autobackup

gd_backup_prepare

create_panel_backup() {
    local file
    file="$GD_BACKUP_PANEL/$(gd_backup_name)"
    if ! gd_backup_panel_space_check; then
        gd_msg "Zu wenig Speicherplatz" "$GD_BACKUP_SPACE_MSG\n\nDas Backup wird nicht erstellt." 11 76
        return
    fi
    clear; echo "Datenbank und Panel-Dateien werden gesichert..."
    if gd_backup_panel_create "$file" true; then
        gd_msg "✔ Backup erstellt" "Das Panel-Backup (Dateien, Konfiguration und Datenbank) wurde erstellt und geprüft:\n\n$file ($(du -h "$file" | cut -f1))\n\nEs werden automatisch die neuesten $GD_BACKUP_KEEP Panel-Backups behalten." 13 78
    else
        gd_msg "✖ Backup fehlgeschlagen" "Das Backup konnte nicht vollständig erstellt werden und wurde verworfen.\n\nMögliche Ursachen: zu wenig Speicherplatz, Datenbank nicht erreichbar.\nDetails: $GD_LOG" 12 78
    fi
}

create_server_backup() {
    local file size free stop=false
    [ -d "$GD_VOLUMES_DIR" ] || { gd_msg "Keine Gameserver" "Unter $GD_VOLUMES_DIR wurden keine Gameserver-Daten gefunden." 8 70; return; }
    size="$(du -sb "$GD_VOLUMES_DIR" | cut -f1)"
    free="$(df -PB1 "$GD_BACKUP_ROOT" | awk 'NR==2{print $4}')"
    if [ "$free" -lt "$size" ]; then
        gd_msg "Zu wenig Speicherplatz" "Die Gameserver belegen $(numfmt --to=iec "$size"), frei sind nur $(numfmt --to=iec "$free"). Das Backup wird nicht erstellt." 10 74
        return
    fi
    if systemctl is-active --quiet wings && gd_yesno "Gameserver anhalten?" "Laufende Gameserver schreiben während des Backups weiter in ihre Dateien. Das kann zu beschädigten Spielständen im Backup führen.\n\nSollen alle Gameserver während des Backups angehalten werden?\n\nEmpfehlung: Ja, sofern gerade niemand spielt." 15 74; then
        stop=true
        clear; echo "Gameserver werden angehalten..."
        gd_backup_stop_servers
    fi
    file="$GD_BACKUP_SERVER/$(gd_backup_name)"
    if gd_backup_server_create "$file" true; then
        $stop && systemctl start wings
        gd_msg "✔ Backup erstellt" "Das Backup aller Gameserver wurde erstellt und geprüft:\n\n$file ($(du -h "$file" | cut -f1))$($stop && echo "\n\nWings läuft wieder und startet die zuvor laufenden Gameserver in Kürze selbst. Gestoppte Server bleiben gestoppt.")" 13 78
    else
        $stop && systemctl start wings
        gd_msg "✖ Backup fehlgeschlagen" "Das Backup konnte nicht vollständig erstellt werden und wurde verworfen. Details: $GD_LOG" 10 74
    fi
}

select_backup() {
    # select_backup <verzeichnis> -> gibt den Pfad des ausgewählten Backups aus
    local dir="$1" files=() items=() i choice
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    if [ ${#files[@]} -eq 0 ]; then
        gd_msg "Keine Backups" "Im Verzeichnis $dir wurden keine Backups gefunden." 8 70
        return 1
    fi
    for i in "${!files[@]}"; do
        items+=("$((i + 1))" "$(basename "${files[$i]}") ($(du -h "${files[$i]}" | cut -f1))")
    done
    choice=$(whiptail --title "Backup auswählen" --menu "Wähle ein Backup aus (neueste zuerst):" 20 78 10 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
    echo "${files[$((choice - 1))]}"
}

restore_panel_backup() {
    local file
    file="$(select_backup "$GD_BACKUP_PANEL")" || return
    gd_yesno "⚠ Wiederherstellen" "Das Panel wird auf den Stand von\n$(basename "$file")\nzurückgesetzt. Alle Änderungen seitdem (Benutzer, Server-Einträge, Einstellungen) gehen verloren.\n\nSchlägt etwas fehl, wird automatisch der vorherige Stand wiederhergestellt.\n\nFortfahren?" 15 74 || return
    clear; echo "Panel wird wiederhergestellt, bitte warten..."
    if gd_backup_panel_restore "$file"; then
        gd_msg "✔ Wiederherstellung abgeschlossen" "$GD_RESTORE_INFO" 10 74
    else
        gd_msg "✖ Wiederherstellung fehlgeschlagen" "$GD_RESTORE_INFO\n\nDetails: $GD_LOG" 11 74
    fi
}

restore_server_backup() {
    local file uuids items=() names uuid name choice target=""
    file="$(select_backup "$GD_BACKUP_SERVER")" || return
    clear; echo "Backup wird gelesen..."
    uuids="$(gd_backup_list_servers_in "$file")"
    [ -z "$uuids" ] && { gd_msg "Leeres Backup" "Das Backup enthält keine Gameserver." 8 60; return; }
    names="$(gd_backup_server_names)"
    items+=("ALLE" "Alle Gameserver im Backup")
    while read -r uuid; do
        name="$(awk -v u="$uuid" '$1==u {$1=""; sub(/^ /,""); print; exit}' <<< "$names")"
        items+=("$uuid" "${name:-(Name unbekannt)}")
    done <<< "$uuids"
    choice=$(whiptail --title "Server wiederherstellen" --menu "Welcher Server soll wiederhergestellt werden?" 20 90 10 "${items[@]}" 3>&1 1>&2 2>&3) || return
    [ "$choice" != "ALLE" ] && target="$choice"

    gd_yesno "⚠ Wiederherstellen" "$( [ -n "$target" ] && echo "Der Server $target" || echo "Alle Gameserver") wird auf den Stand von\n$(basename "$file")\nzurückgesetzt. Dateien, die seitdem entstanden sind, werden entfernt.\n\nDafür werden Wings und alle Gameserver kurz angehalten.\n\nFortfahren?" 15 78 || return
    clear; echo "Gameserver werden angehalten und das Backup wird eingespielt..."
    gd_backup_stop_servers
    if gd_backup_server_restore "$file" "$target"; then
        systemctl start wings 2>/dev/null
        gd_msg "✔ Wiederherstellung abgeschlossen" "Die Daten wurden wiederhergestellt und Wings läuft wieder. Wings startet die zuvor laufenden Gameserver in Kürze selbst wieder; gestoppte Server bleiben gestoppt." 10 74
    else
        systemctl start wings 2>/dev/null
        gd_msg "✖ Wiederherstellung fehlgeschlagen" "Das Backup konnte nicht eingespielt werden. Der vorherige Stand wurde beibehalten.\n\nDetails: $GD_LOG" 11 74
    fi
}

remove_backups() {
    local dir="$1" count
    count="$(find "$dir" -maxdepth 1 -type f -name '*.tar.gz' | wc -l)"
    [ "$count" -eq 0 ] && { gd_msg "Keine Backups" "In $dir gibt es keine Backups." 8 60; return; }
    if gd_yesno "Backups löschen" "Alle $count Backups in\n$dir\nwerden unwiderruflich gelöscht. Fortfahren?" 11 70; then
        find "$dir" -maxdepth 1 -type f -name '*.tar.gz' -delete
        gd_msg "Gelöscht" "Alle Backups wurden gelöscht." 8 50
    fi
}

backup_menu() {
    local kind="$1" choice
    while true; do
        choice=$(whiptail --title "$([ "$kind" = panel ] && echo "Panel-Backups" || echo "Server-Backups")" --menu "Wähle eine Option:" 14 60 4 \
            "1" "Backup erstellen" \
            "2" "Backup wiederherstellen" \
            "3" "Alle Backups löschen" \
            "4" "Zurück" 3>&1 1>&2 2>&3) || return
        case "$kind:$choice" in
            panel:1) create_panel_backup ;;
            panel:2) restore_panel_backup ;;
            panel:3) remove_backups "$GD_BACKUP_PANEL" ;;
            server:1) create_server_backup ;;
            server:2) restore_server_backup ;;
            server:3) remove_backups "$GD_BACKUP_SERVER" ;;
            *) return ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Automatische inkrementelle Backups (restic)
# ---------------------------------------------------------------------------
ab_ask_local() {
    # Lokaler Pfad -> AB_REPO. Rückgabe 1 = zurück zur Auswahl der Zielart
    local repo
    while true; do
        repo="$(gd_input "▸ Lokaler Pfad" "In welchen Ordner sollen die Backups gespeichert werden?\n\nTipp: Ein eingehängtes externes Laufwerk (z. B. /mnt/backup) schützt auch vor einem Festplattenausfall dieses Servers." "$GD_BACKUP_ROOT/restic" 13 74)" || return 1
        repo="${repo%/}"
        if [ -z "$repo" ] || ! [[ "$repo" =~ ^/[A-Za-z0-9._/@+-]*$ ]]; then
            gd_msg "Ungültiger Pfad" "Bitte gib einen absoluten Pfad an (beginnend mit /, nicht nur /).\nErlaubt sind Buchstaben, Ziffern und die Zeichen . _ - / @ +" 9 70
            continue
        fi
        if gd_ab_repo_on_root "$repo"; then
            gd_yesno "⚠ Gleiche Platte wie das System" "Der Ordner $repo liegt auf derselben Platte wie /.\n\nBei einem Festplattenausfall sind Backup und Daten zugleich verloren – besser ein eingehängtes externes Laufwerk oder ein Netzwerkziel.\n\nTrotzdem hier speichern?" 14 74 || return 1
        fi
        AB_REPO="$repo"
        return 0
    done
}

ab_ssh_key() {
    # Erster private SSH-Schlüssel in /root/.ssh (id_*, ohne .pub), leer wenn keiner existiert
    local f
    for f in /root/.ssh/id_*; do
        [ -f "$f" ] && [[ "$f" != *.pub ]] && { echo "$f"; return 0; }
    done
    return 1
}

ab_sftp_prepare() {
    # ab_sftp_prepare <host> <port> – SSH-Schlüssel und Host-Schlüssel für SFTP vorbereiten. Rückgabe 1 = Abbruch
    local host="${1#[}" port="$2" entry scan keyfile
    host="${host%]}"
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    # restic verbindet sich als root über ssh: Der Schlüssel liegt in /root/.ssh und darf KEINE Passphrase haben,
    # weil der nächtliche Lauf nicht danach fragen kann.
    if [ -z "$(ab_ssh_key)" ]; then
        if gd_yesno "SSH-Schlüssel anlegen?" "In /root/.ssh gibt es noch keinen SSH-Schlüssel. Für die automatischen Backups wird einer ohne Passphrase benötigt (der nächtliche Lauf kann keine Passphrase eingeben).\n\nSoll jetzt ein Schlüssel (ed25519, ohne Passphrase) angelegt werden?" 13 74; then
            ssh-keygen -q -t ed25519 -N '' -C germandactyl-backup -f /root/.ssh/id_ed25519 >> "$GD_LOG" 2>&1
        fi
    fi
    keyfile="$(ab_ssh_key)"
    if [ -n "$keyfile" ] && [ -f "$keyfile.pub" ]; then
        gd_msg "SSH-Schlüssel hinterlegen" "Dieser öffentliche Schlüssel muss beim Backup-Ziel hinterlegt sein (z. B. in den Einstellungen der Storage Box oder in ~/.ssh/authorized_keys):\n\n$(cat "$keyfile.pub")\n\nDer Schlüssel muss ohne Passphrase in /root/.ssh liegen." 16 78
    else
        gd_msg "SSH-Schlüssel fehlt" "Lege einen SSH-Schlüssel ohne Passphrase in /root/.ssh an, z. B.:\n\nssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519\n\nund hinterlege den öffentlichen Schlüssel (.pub) beim Backup-Ziel. Die Einrichtung prüft die Verbindung gleich." 13 78
    fi
    # Host-Schlüssel des Ziels in known_hosts eintragen (sonst fragt ssh nachts nach und das Backup scheitert)
    entry="$host"; [ "$port" != "22" ] && entry="[$host]:$port"
    if ! ssh-keygen -F "$entry" -f /root/.ssh/known_hosts >/dev/null 2>&1; then
        scan="$(timeout 20 ssh-keyscan -p "$port" -t ed25519,ecdsa,rsa "$host" 2>/dev/null)"
        if [ -z "$scan" ]; then
            gd_msg "Server nicht erreichbar" "Der Server $host antwortet nicht auf Port $port. Prüfe Adresse und Port (bei Hetzner Storage Boxes: 23)." 9 74
            return 1
        fi
        gd_yesno "Host-Schlüssel eintragen?" "Der Server $host ist noch nicht bekannt. Sein Fingerabdruck:\n\n$(ssh-keygen -lf - <<< "$scan" 2>/dev/null | awk '{print $4 " " $2}' | head -n 3)\n\nVergleiche ihn mit den Angaben deines Anbieters. Soll der Schlüssel in /root/.ssh/known_hosts eingetragen werden?" 16 78 || return 1
        printf '%s\n' "$scan" >> /root/.ssh/known_hosts
    fi
    return 0
}

ab_ask_sftp() {
    # SFTP -> AB_REPO (restic-Adresse sftp://benutzer@server:port//pfad)
    local userhost port path host
    userhost="$(gd_input "SFTP – Benutzer und Server" "Benutzer und Server im Format benutzer@server\n\nBeispiel (Hetzner Storage Box):\nu123456@u123456.your-storagebox.de" "" 12 74)" || return 1
    if ! [[ "$userhost" =~ ^[A-Za-z0-9._-]+@([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])$ ]]; then
        gd_msg "Ungültige Eingabe" "Bitte gib Benutzer und Server im Format benutzer@server an." 8 66; return 1
    fi
    host="${userhost#*@}"
    port="$(gd_input "SFTP – Port" "SSH-Port des Ziels (meist 22, bei Hetzner Storage Boxes 23):" "22" 9 70)" || return 1
    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        gd_msg "Ungültiger Port" "Bitte gib eine Portnummer zwischen 1 und 65535 an." 8 60; return 1
    fi
    path="$(gd_input "SFTP – Ordner" "Ordner auf dem Ziel, in dem das Archiv liegen soll.\n\nBeginnt der Pfad mit /, ist er absolut (z. B. /home/backup/restic), sonst gilt er relativ zum Home-Verzeichnis des Benutzers (z. B. restic-backup). Der Ordner wird angelegt, falls er fehlt." "restic-backup" 14 74)" || return 1
    if ! [[ "$path" =~ ^[A-Za-z0-9._/@+-]+$ ]]; then
        gd_msg "Ungültiger Pfad" "Erlaubt sind Buchstaben, Ziffern und die Zeichen . _ - / @ +" 8 70; return 1
    fi
    ab_sftp_prepare "$host" "$port" || return 1
    # restic-Syntax: sftp://benutzer@server:port//absoluter/pfad bzw. sftp://benutzer@server:port/relativer/pfad
    AB_REPO="sftp://${userhost}:${port}/${path}"
    return 0
}

ab_ask_s3() {
    # S3 -> AB_REPO (s3:https://endpunkt/bucket), Zugangsdaten in GD_AB_AWS_KEY / GD_AB_AWS_SECRET (landen nur in auto-backup.conf, 600)
    local endpoint bucket key secret
    endpoint="$(gd_input "S3 – Endpunkt" "Adresse des S3-Dienstes (mit https://)\n\nBeispiele:\nAmazon S3 (Frankfurt):  https://s3.eu-central-1.amazonaws.com\nBackblaze B2:          https://s3.eu-central-003.backblazeb2.com\nWasabi:                https://s3.eu-central-1.wasabisys.com\nMinIO (eigener Server): https://minio.example.com:9000" "https://s3.eu-central-1.amazonaws.com" 17 78)" || return 1
    endpoint="${endpoint%/}"
    if ! [[ "$endpoint" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
        gd_msg "Ungültige Adresse" "Bitte gib die Adresse im Format https://server an (ohne Pfad)." 8 66; return 1
    fi
    bucket="$(gd_input "S3 – Bucket" "Name des Buckets, optional mit Unterordner (bucket/ordner).\n\nDas Bucket muss bereits existieren." "" 11 70)" || return 1
    if ! [[ "$bucket" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9._/-]+)?$ ]]; then
        gd_msg "Ungültiger Name" "Bitte gib den Bucket-Namen an, optional mit Unterordner (bucket/ordner)." 8 70; return 1
    fi
    key="$(gd_whip --title "S3 – Zugangsdaten" --passwordbox "Access Key ID (AWS_ACCESS_KEY_ID):" 9 70 3>&1 1>&2 2>&3)" || return 1
    secret="$(gd_whip --title "S3 – Zugangsdaten" --passwordbox "Secret Access Key (AWS_SECRET_ACCESS_KEY):" 9 70 3>&1 1>&2 2>&3)" || return 1
    if ! [[ "$key" =~ ^[A-Za-z0-9/+=_.-]+$ ]] || ! [[ "$secret" =~ ^[A-Za-z0-9/+=_.-]+$ ]]; then
        gd_msg "Ungültige Zugangsdaten" "Access Key und Secret dürfen nicht leer sein und keine Leerzeichen enthalten." 8 70; return 1
    fi
    # shellcheck disable=SC2034
    GD_AB_AWS_KEY="$key"
    # shellcheck disable=SC2034
    GD_AB_AWS_SECRET="$secret"
    AB_REPO="s3:${endpoint}/${bucket}"
    return 0
}

ab_ask_rest() {
    # rest-server -> AB_REPO (rest:https://benutzer:passwort@server:8000/pfad)
    local url user pass scheme hostport path auth=""
    url="$(gd_input "rest-server – Adresse" "Adresse des restic REST-Servers, z. B.\nhttps://backup.example.com:8000/ oder https://backup.example.com:8000/mein-archiv/" "https://" 12 74)" || return 1
    if ! [[ "$url" =~ ^(https?)://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?(/[A-Za-z0-9._/-]*)?$ ]]; then
        gd_msg "Ungültige Adresse" "Bitte gib die Adresse im Format https://server:8000/ an." 8 66; return 1
    fi
    scheme="${BASH_REMATCH[1]}"; hostport="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"; path="${BASH_REMATCH[4]:-/}"
    user="$(gd_input "rest-server – Benutzer" "Benutzername (leer lassen, wenn der Server ohne Anmeldung arbeitet):" "" 9 70)" || return 1
    if [ -n "$user" ]; then
        pass="$(gd_whip --title "rest-server – Passwort" --passwordbox "Passwort für $user:" 9 70 3>&1 1>&2 2>&3)" || return 1
        # Sonderzeichen in Benutzer und Passwort für die Adresse kodieren
        auth="$(printf '%s' "$user" | jq -sRr @uri):$(printf '%s' "$pass" | jq -sRr @uri)@"
    fi
    [ "$scheme" = "http" ] && gd_msg "Unverschlüsselte Verbindung" "Die Verbindung per http ist unverschlüsselt. Die Backup-Daten selbst sind zwar verschlüsselt, Benutzername und Passwort des Servers aber nicht. Besser: https." 10 74
    AB_REPO="rest:${scheme}://${auth}${hostport}${path}"
    return 0
}

ab_ask_target() {
    # Fragt Zielart und Zieldaten ab. Setzt AB_REPO (und bei S3 GD_AB_AWS_KEY/GD_AB_AWS_SECRET). Rückgabe 1 = Abbruch
    local kind
    AB_REPO=""
    # GD_AB_AWS_KEY/GD_AB_AWS_SECRET werden von gd_ab_write_conf (lib/autobackup.sh) gelesen
    # shellcheck disable=SC2034
    GD_AB_AWS_KEY=""
    # shellcheck disable=SC2034
    GD_AB_AWS_SECRET=""
    while true; do
        kind=$(whiptail --title "▸ Speicherort" --menu "Wohin sollen die Backups gespeichert werden?\n\nEin Ziel außerhalb dieses Servers schützt auch vor dem Ausfall des ganzen Servers." 18 78 4 \
            "1" "Lokaler Pfad (Ordner oder eingehängtes Laufwerk)" \
            "2" "SFTP (z. B. Storage Box oder anderer Server per SSH)" \
            "3" "S3 (Amazon S3, Backblaze B2, Wasabi, MinIO, ...)" \
            "4" "rest-server (restic REST-Server)" 3>&1 1>&2 2>&3) || return 1
        case "$kind" in
            1) ab_ask_local && return 0 ;;
            2) ab_ask_sftp && return 0 ;;
            3) ab_ask_s3 && return 0 ;;
            4) ab_ask_rest && return 0 ;;
        esac
    done
}

ab_setup_dialog() {
    local servers=false time rc
    gd_msg "◷ Automatische Backups" "Automatische Backups laufen jeden Tag von selbst und sind inkrementell: Nach dem ersten Backup werden nur noch Änderungen gespeichert. Das spart viel Speicherplatz und Zeit.\n\nGesichert werden:\n- Panel-Dateien und Konfigurationen (nginx, Wings, Zertifikate, Dienste)\n- ALLE Datenbanken samt Benutzern (Panel und Datenbanken deiner Gameserver)\n- optional die Dateien aller Gameserver\n\nAufbewahrt werden 7 tägliche, 4 wöchentliche und 6 monatliche Stände. Das Archiv ist verschlüsselt (restic) und wird jeden Sonntag auf Beschädigungen geprüft.\n\nSpeicherort: lokaler Ordner, SFTP, S3 oder rest-server." 21 78
    if gd_yesno "⚑ Gameserver mitsichern?" "Sollen auch die Dateien aller Gameserver (Welten, Spielstände, Plugins) gesichert werden?\n\nDas erste Backup kann je nach Größe länger dauern, danach werden nur Änderungen gespeichert.\nAktuell belegt: $(du -sh "$GD_VOLUMES_DIR" 2>/dev/null | cut -f1 || echo 0)\n\nHinweis: Das Backup läuft im laufenden Betrieb. Laufende Gameserver schreiben währenddessen weiter, deshalb können Spielstände im Backup inkonsistent sein." 17 74; then
        servers=true
    fi
    while true; do
        time="$(gd_input "◷ Uhrzeit" "Um wie viel Uhr soll das tägliche Backup laufen? (Format HH:MM, am besten nachts)" "04:00" 10 70)" || return
        [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
        gd_msg "Ungültige Uhrzeit" "Bitte gib die Uhrzeit im Format HH:MM an, z. B. 04:00." 8 60
    done
    ab_ask_target || return

    gd_gauge_open "◷ Automatische Backups" "Einrichtung läuft..."
    gd_progress 20 "restic wird installiert, das Ziel wird geprüft, das Archiv wird angelegt..."
    gd_ab_setup "$AB_REPO" "$servers" "$time" >> "$GD_LOG" 2>&1
    rc=$?
    [ $rc -eq 0 ] && { gd_progress 70 "jq wird installiert..."; gd_apt_install jq >> "$GD_LOG" 2>&1; }
    gd_progress 100 "Fertig."
    gd_gauge_close
    unset GD_AB_AWS_KEY GD_AB_AWS_SECRET
    if [ $rc -ne 0 ]; then
        gd_msg "✖ Einrichtung fehlgeschlagen" "${GD_AB_ERROR:-Die Einrichtung ist fehlgeschlagen.}\n\nEs wurde nichts verändert. Details: $GD_LOG" 14 78
        return
    fi
    gd_conf_set AUTO_BACKUP_SETUP "$(date '+%F %T')"

    gd_msg_secret "✱ Wichtig: Passwort des Backup-Archivs" "Die Backups sind verschlüsselt. Ohne dieses Passwort können sie NICHT wiederhergestellt werden, falls dieser Server ausfällt:\n\n$(cat "$GD_AB_PASS")\n\nSpeichere es an einem sicheren Ort (z. B. Passwortmanager). Auf dem Server liegt es in $GD_AB_PASS." 16 78
    if gd_yesno "Erstes Backup" "Die automatischen Backups sind eingerichtet (täglich um $time Uhr).\n\nSoll das erste Backup jetzt sofort erstellt werden?" 10 70; then
        ab_run_now
    fi
}

ab_run_now() {
    clear
    echo "Backup läuft... (Fortschritt: tail -f /var/log/germandactyl-setup/auto-backup.log)"
    echo "Es läuft als Systemdienst weiter, auch wenn die SSH-Verbindung abbricht."
    local rc
    # Über systemd starten: ein Abbruch der SSH-Sitzung beendet restic dann nicht (keine verwaisten Sperren)
    systemctl start germandactyl-backup.service >> "$GD_LOG" 2>&1
    rc=$?
    if [ $rc -eq 0 ] && tail -n 3 /var/log/germandactyl-setup/auto-backup.log | grep -q "läuft bereits"; then
        gd_msg "Backup läuft bereits" "Es läuft gerade schon ein Backup (z. B. der nächtliche Lauf). Versuche es später erneut." 9 70
        return
    fi
    if [ $rc -eq 0 ]; then
        gd_msg "✔ Backup erfolgreich" "Das Backup wurde erstellt.\n\n$(tail -n 4 /var/log/germandactyl-setup/auto-backup.log | cut -c1-90)" 13 90
    else
        gd_msg "✖ Backup mit Fehlern" "Das Backup ist fehlgeschlagen oder unvollständig.\n\n$(grep -E 'FEHLER|Warnung' /var/log/germandactyl-setup/auto-backup.log | tail -n 5 | cut -c1-90)\n\nLog: /var/log/germandactyl-setup/auto-backup.log" 16 90
    fi
}

ab_last_result() {
    # Letztes Ergebnis als Text; "laufend" länger als 6 Stunden gilt als hängend/abgebrochen (wie in Statuszeile und Analyse)
    local res run age
    res="$(gd_conf_get AUTO_BACKUP_LAST_RESULT)"; run="$(gd_conf_get AUTO_BACKUP_LAST_RUN)"
    case "$res" in
        ok) echo "erfolgreich${run:+ ($run)}" ;;
        fehler) echo "FEHLGESCHLAGEN${run:+ ($run)} – siehe Log" ;;
        laufend)
            age=0
            [ -n "$run" ] && age=$(( $(date +%s) - $(date -d "$run" +%s 2>/dev/null || date +%s) ))
            if [ "$age" -gt 21600 ]; then echo "hängt oder wurde abgebrochen (gestartet $run)"; else echo "läuft gerade"; fi ;;
        *) echo "noch keiner" ;;
    esac
}

ab_status() {
    local snaps count next size
    gd_ab_load
    snaps="$(gd_ab_snapshots)"
    count="$(grep -c . <<< "$snaps")"
    next="$(systemctl list-timers germandactyl-backup.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}')"
    case "$(gd_ab_repo_kind "$REPO")" in
        lokal) size="$(du -sh "$REPO" 2>/dev/null | cut -f1)" ;;
        *) size="" ;;
    esac
    gd_msg "☰ Status der automatischen Backups" "Zeitplan:        täglich um $TIME Uhr ($(systemctl is-active germandactyl-backup.timer))\nNächster Lauf:   ${next:-unbekannt}\nLetzter Lauf:    $(ab_last_result)\nLetzter Erfolg:  $(gd_conf_get AUTO_BACKUP_LAST_OK | grep . || echo noch keiner)\nGameserver:      $( [ "$INCLUDE_SERVERS" = true ] && echo mitgesichert || echo nicht gesichert)\nSpeicherort:     $(gd_ab_mask_repo "$REPO")${size:+ ($size)}\nStände:          $count\n\nNeueste Stände:\n$(head -n 5 <<< "$snaps" | awk '{print "  " $2 " " $3 "  (" $1 ")" ($5 == "unv" ? "  ohne vollständige Datenbanken" : "")}')" 23 80
}

ab_offer_grants() {
    # ab_offer_grants <snapshot> – Datenbank-Benutzer nach einer Wiederherstellung anbieten (nur wenn der Stand sie enthält; Standard: Nein)
    local rc
    gd_ab_has_grants "$1" || return 0
    gd_ab_restore_grants "$1"; rc=$?
    case $rc in
        0) gd_msg "✔ Benutzer eingespielt" "$GD_RESTORE_INFO" 8 70 ;;
        1) gd_msg "✖ Fehlgeschlagen" "$GD_RESTORE_INFO\n\nDetails: $GD_LOG" 10 70 ;;
    esac
}

ab_restore() {
    local snaps items=() snap what choice names uuid name dbs paneldb hidden id d t srv kind rc
    snaps="$(gd_ab_snapshots)"
    [ -z "$snaps" ] && { gd_msg "Keine Backups" "Es gibt noch keine automatischen Backups." 8 60; return; }
    while read -r id d t srv kind; do
        items+=("$id" "$d $t Uhr$( [ "$srv" = ja ] && echo ' (mit Gameservern)')$( [ "$kind" = unv ] && echo ' [ohne Datenbanken]')")
    done <<< "$snaps"
    snap=$(whiptail --title "Stand auswählen" --menu "Welcher Stand soll wiederhergestellt werden? (neueste zuerst)\n\n[ohne Datenbanken] = bei diesem Lauf waren die Datenbanken nicht erreichbar." 21 78 10 "${items[@]}" 3>&1 1>&2 2>&3) || return
    what=$(whiptail --title "Was wiederherstellen?" --menu "Was soll aus dem Stand $snap wiederhergestellt werden?" 18 78 5 \
        "PANEL" "Panel komplett (Dateien, Konfiguration, Panel-Datenbank)" \
        "DB" "Eine einzelne Datenbank (z. B. eines Gameservers)" \
        "SERVER" "Gameserver-Dateien" \
        "KONFIG" "nginx, Zertifikate, Wings-Konfiguration" \
        "BENUTZER" "Datenbank-Benutzer und Rechte (nur auf Nachfrage)" 3>&1 1>&2 2>&3) || return
    case "$what" in
        PANEL)
            gd_yesno "⚠ Panel wiederherstellen" "Das Panel wird auf den gewählten Stand zurückgesetzt. Änderungen seitdem gehen verloren. Schlägt etwas fehl, wird der vorherige Stand automatisch wiederhergestellt.\n\nFortfahren?" 12 74 || return
            clear; echo "Panel wird wiederhergestellt..."
            if gd_ab_restore_panel "$snap"; then
                gd_msg "✔ Wiederhergestellt" "$GD_RESTORE_INFO" 10 74
                ab_offer_grants "$snap"
            else gd_msg "✖ Fehlgeschlagen" "$GD_RESTORE_INFO\n\nDetails: $GD_LOG" 11 74; fi ;;
        DB)
            clear; echo "Stand wird gelesen..."
            dbs="$(gd_ab_list_dbs "$snap")"
            [ -z "$dbs" ] && { gd_msg "Keine Datenbanken" "Dieser Stand enthält keine Datenbanken." 8 60; return; }
            # Die Panel-Datenbank gehört zum Panel (Dateien und Datenbank müssen zusammenpassen): Menüpunkt PANEL
            paneldb=""; [ -f "$PTERO_DIR/.env" ] && paneldb="$(gd_backup_panel_db)"
            items=(); hidden=false
            for name in $dbs; do
                if [ -n "$paneldb" ] && [ "$name" = "$paneldb" ]; then hidden=true; continue; fi
                items+=("$name" "")
            done
            if [ ${#items[@]} -eq 0 ]; then
                gd_msg "Nur die Panel-Datenbank" "Dieser Stand enthält nur die Panel-Datenbank ($paneldb). Sie wird zusammen mit den Panel-Dateien wiederhergestellt – wähle dafür im vorigen Menü PANEL." 10 74
                return
            fi
            choice=$(whiptail --title "Datenbank wählen" --menu "Welche Datenbank soll wiederhergestellt werden?$($hidden && echo "\n\nDie Panel-Datenbank ($paneldb) fehlt hier mit Absicht: Sie wird über den Punkt PANEL zusammen mit den Panel-Dateien wiederhergestellt.")" 22 74 10 "${items[@]}" 3>&1 1>&2 2>&3) || return
            gd_yesno "⚠ Datenbank wiederherstellen" "Die Datenbank '$choice' wird auf den gewählten Stand zurückgesetzt. Der aktuelle Inhalt wird vorher gesichert und bei einem Fehler zurückgespielt. Währenddessen ruhen der Queue-Dienst (pteroq) und Cron kurz.\n\nFortfahren?" 13 74 || return
            clear; echo "Datenbank wird wiederhergestellt..."
            if gd_ab_restore_db "$snap" "$choice"; then gd_msg "✔ Wiederhergestellt" "Die Datenbank '$choice' wurde wiederhergestellt." 8 70
            else gd_msg "✖ Fehlgeschlagen" "Die Datenbank konnte nicht wiederhergestellt werden, der vorherige Inhalt ist unverändert.\n\nDetails: $GD_LOG" 11 74; fi ;;
        SERVER)
            clear; echo "Stand wird gelesen..."
            local uuids; uuids="$(gd_ab_list_servers "$snap")"
            [ -z "$uuids" ] && { gd_msg "Keine Gameserver" "Dieser Stand enthält keine Gameserver-Dateien." 8 60; return; }
            names="$(gd_backup_server_names)"
            items=("ALLE" "Alle Gameserver")
            while read -r uuid; do
                name="$(awk -v u="$uuid" '$1==u {$1=""; sub(/^ /,""); print; exit}' <<< "$names")"
                items+=("$uuid" "${name:-(Name unbekannt)}")
            done <<< "$uuids"
            choice=$(whiptail --title "Server wählen" --menu "Welcher Gameserver soll wiederhergestellt werden?" 20 90 10 "${items[@]}" 3>&1 1>&2 2>&3) || return
            [ "$choice" = "ALLE" ] && choice=""
            gd_yesno "⚠ Gameserver wiederherstellen" "$( [ -n "$choice" ] && echo "Der Server $choice" || echo "Alle Gameserver") wird auf den gewählten Stand zurückgesetzt. Wings und alle Gameserver werden dafür kurz angehalten.\n\nFortfahren?" 12 78 || return
            clear; echo "Gameserver werden angehalten und wiederhergestellt..."
            gd_backup_stop_servers
            if gd_ab_restore_server "$snap" "$choice"; then
                systemctl start wings 2>/dev/null
                gd_msg "✔ Wiederhergestellt" "Die Gameserver-Dateien wurden wiederhergestellt und Wings läuft wieder. Wings startet die zuvor laufenden Gameserver in Kürze selbst wieder; gestoppte Server bleiben gestoppt." 10 74
            else
                systemctl start wings 2>/dev/null
                gd_msg "✖ Fehlgeschlagen" "Die Wiederherstellung ist fehlgeschlagen, der vorherige Stand wurde beibehalten.\n\nDetails: $GD_LOG" 11 74
            fi ;;
        KONFIG)
            gd_yesno "⚠ Konfiguration wiederherstellen" "Aus dem gewählten Stand werden wiederhergestellt: nginx, Zertifikate (/etc/letsencrypt), die Konfiguration von Wings und Panel (/etc/pterodactyl bzw. /etc/pelican), /etc/germandactyl, die systemd-Units und die Crontabs. Vorhandene Dateien werden überschrieben.\n\nVorher wird der aktuelle Stand gesichert nach:\n$GD_BACKUP_ROOT/konfig-vor-wiederherstellung-<Datum>.tar.gz\n\nDanach werden nginx neu geladen und Wings neu gestartet.\n\nFortfahren?" 18 78 || return
            clear; echo "Konfiguration wird wiederhergestellt..."
            if gd_ab_restore_config "$snap"; then gd_msg "✔ Wiederhergestellt" "$GD_RESTORE_INFO" 13 78
            else gd_msg "✖ Nicht vollständig" "$GD_RESTORE_INFO\n\nDetails: $GD_LOG" 15 78; fi ;;
        BENUTZER)
            gd_ab_restore_grants "$snap"; rc=$?
            case $rc in
                0) gd_msg "✔ Wiederhergestellt" "$GD_RESTORE_INFO" 8 74 ;;
                1) gd_msg "✖ Fehlgeschlagen" "$GD_RESTORE_INFO\n\nDetails: $GD_LOG" 10 74 ;;
                *) gd_msg "Keine Änderung" "$GD_RESTORE_INFO" 9 74 ;;
            esac ;;
    esac
}

ab_settings() {
    gd_ab_load
    local servers="$INCLUDE_SERVERS" time="$TIME"
    if gd_yesno "⚑ Gameserver mitsichern?" "Sollen die Dateien aller Gameserver mitgesichert werden?\n\nAktuell: $( [ "$servers" = true ] && echo ja || echo nein)\n\nHinweis: Das Backup läuft im laufenden Betrieb. Laufende Gameserver schreiben währenddessen weiter, deshalb können Spielstände im Backup inkonsistent sein." 14 74; then servers=true; else servers=false; fi
    while true; do
        time="$(gd_input "◷ Uhrzeit" "Uhrzeit des täglichen Backups (HH:MM):" "$TIME" 9 60)" || return
        [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
    done
    gd_ab_write_conf "$REPO" "$servers" "$time" "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_MONTHLY"
    gd_ab_write_units "$time" "$REPO" >> "$GD_LOG" 2>&1
    gd_msg "Gespeichert" "Die Einstellungen wurden übernommen." 8 50
}

ab_menu() {
    local choice
    if ! gd_ab_installed; then
        ab_setup_dialog
        gd_ab_installed || return
    fi
    while true; do
        choice=$(whiptail --title "◷ Automatische Backups" --menu "Status: $(systemctl is-active germandactyl-backup.timer) – letzter Lauf: $(ab_last_result)\nLetzter Erfolg: $(gd_conf_get AUTO_BACKUP_LAST_OK | grep . || echo noch keiner)" 18 78 6 \
            "1" "Status anzeigen" \
            "2" "Jetzt sichern" \
            "3" "Wiederherstellen" \
            "4" "Einstellungen ändern" \
            "5" "Automatische Backups deaktivieren" \
            "6" "Zurück" 3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) ab_status ;;
            2) ab_run_now ;;
            3) ab_restore ;;
            4) ab_settings ;;
            5) if gd_yesno "Deaktivieren" "Die automatischen Backups werden abgeschaltet. Vorhandene Backups bleiben erhalten und können weiterhin wiederhergestellt werden.\n\nFortfahren?" 11 70; then
                   systemctl disable --now germandactyl-backup.timer >> "$GD_LOG" 2>&1
                   gd_msg "Deaktiviert" "Die automatischen Backups sind abgeschaltet. Über 'Einstellungen ändern' kannst du sie wieder aktivieren." 9 70
               fi ;;
            *) return ;;
        esac
    done
}

gd_msg "↺ Backup-Verwaltung" "Hier erstellst du Backups deines Panels (Dateien, Konfiguration und Datenbank) und deiner Gameserver. Jedes Backup wird nach dem Erstellen auf Vollständigkeit geprüft.\n\nAblage: $GD_BACKUP_ROOT\n\nTipp: Ein Backup auf demselben Server schützt nicht vor einem Festplattenausfall. Kopiere wichtige Backups zusätzlich an einen anderen Ort." 15 76

while true; do
    choice=$(whiptail --title "↺ Backup-Verwaltung" --menu "Wähle die Backup-Art:" 15 70 4 \
        "1" "◷ Automatische Backups (täglich, inkrementell)" \
        "2" "Panel-Backups (manuell)" \
        "3" "Server-Backups (manuell, Gameserver)" \
        "4" "Zurück zum Hauptmenü" 3>&1 1>&2 2>&3) || exit 0
    case "$choice" in
        1) ab_menu ;;
        2) backup_menu panel ;;
        3) backup_menu server ;;
        *) exit 0 ;;
    esac
done
