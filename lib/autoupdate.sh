#!/bin/bash
# Pfad: lib/autoupdate.sh
# Geplante Updates von Panel und Wings als systemd-Timer (standardmäßig AUS, nur über das Menü mit Warnung aktivierbar).
# Der Timer startet /usr/local/sbin/germandactyl-update. Das Skript lädt wie der Kurzbefehl "germandactyl" installer.sh
# und startet es mit --auto-update, das gd_autoupdate_run im Headless-Modus (GD_HEADLESS=1,
# keine Dialoge) ausführt. Rückmeldung gibt es nur über die Statuszeile im Hauptmenü, die Analyse und den Login-Hinweis
# (MOTD) – es werden keine E-Mails oder Webhooks verschickt.
# Benötigt: common, panel, wings, manage (gd_shortcut_body, gd_submenu, gd_has_panel, gd_has_wings)

GD_AU_CONF="$GD_CONF_DIR/auto-update.conf"
GD_AU_SCRIPT="/usr/local/sbin/germandactyl-update"
GD_AU_LOG="$GD_LOG_DIR/auto-update.log"
GD_AU_UNIT_DIR="/etc/systemd/system"
GD_AU_LOCK="/run/germandactyl-update.lock"
GD_AU_BACKUP_LOCK="/run/germandactyl-backup.lock"
GD_AU_DAYS="Mon Tue Wed Thu Fri Sat Sun"

# ---------------------------------------------------------------------------
# Einstellungen (auto-update.conf: PANEL, WINGS, REAPPLY, TIME, DAY)
# ---------------------------------------------------------------------------
gd_au_valid_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }

gd_au_valid_day() {
    local d
    [ "$1" = daily ] && return 0
    for d in $GD_AU_DAYS; do [ "$1" = "$d" ] && return 0; done
    return 1
}

gd_au_day_name() {
    # Mon -> Montag, daily -> täglich
    case "$1" in
        Mon) echo "montags" ;; Tue) echo "dienstags" ;; Wed) echo "mittwochs" ;; Thu) echo "donnerstags" ;;
        Fri) echo "freitags" ;; Sat) echo "samstags" ;; Sun) echo "sonntags" ;; *) echo "täglich" ;;
    esac
}

gd_au_get() {
    # gd_au_get KEY [vorgabe] – Wert aus auto-update.conf
    local v
    v="$(sed -n "s/^$1=//p" "$GD_AU_CONF" 2>/dev/null | tail -n1)"
    echo "${v:-${2:-}}"
}

gd_au_backup_time() {
    # Uhrzeit des automatischen Backups (Standard 04:00)
    local t
    t="$(sed -n 's/^TIME=//p' "$GD_CONF_DIR/auto-backup.conf" 2>/dev/null | tail -n1)"
    gd_au_valid_time "$t" && echo "$t" || echo "04:00"
}

gd_au_default_time() {
    # 30 Minuten nach dem automatischen Backup (Standard 04:00 -> 04:30), damit sich beide nicht überschneiden
    date -d "2000-01-01 $(gd_au_backup_time) 30 minutes" +%H:%M 2>/dev/null || echo "04:30"
}

gd_autoupdate_write_conf() {
    # gd_autoupdate_write_conf <panel true/false> <wings true/false> <reapply true/false> <HH:MM> <daily|Mon..Sun>
    gd_au_valid_time "$4" && gd_au_valid_day "$5" || return 1
    mkdir -p "$GD_CONF_DIR"; chmod 700 "$GD_CONF_DIR"
    cat > "$GD_AU_CONF" <<EOF
# Angelegt von GermanDactyl Setup – Einstellungen der automatischen Updates
PANEL=$1
WINGS=$2
REAPPLY=$3
TIME=$4
DAY=$5
EOF
    chmod 600 "$GD_AU_CONF"
}

# ---------------------------------------------------------------------------
# Skript und systemd-Units
# ---------------------------------------------------------------------------
gd_autoupdate_write_script() {
    # Dasselbe Startskript wie der Kurzbefehl mit GD_HEADLESS=1 und --auto-update
    declare -F gd_shortcut_body >/dev/null || return 1
    mkdir -p "$(dirname "$GD_AU_SCRIPT")"
    gd_shortcut_body "$GD_AU_SCRIPT" update > "$GD_AU_SCRIPT" || return 1
    chmod 750 "$GD_AU_SCRIPT"
}

gd_autoupdate_write_units() {
    # gd_autoupdate_write_units <HH:MM> <daily|Mon..Sun> – schreibt Service und Timer (ohne sie zu aktivieren)
    local time="$1" day="$2" cal
    gd_au_valid_time "$time" && gd_au_valid_day "$day" || return 1
    if [ "$day" = daily ]; then cal="*-*-* ${time}:00"; else cal="${day} *-*-* ${time}:00"; fi
    mkdir -p "$GD_AU_UNIT_DIR"
    cat > "$GD_AU_UNIT_DIR/germandactyl-update.service" <<EOF
[Unit]
Description=GermanDactyl Setup – geplantes Update von Panel und Wings
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=oneshot
# HOME, damit mariadb-dump und composer eine /root/.my.cnf bzw. ~/.composer finden
Environment=HOME=/root
ExecStart=$GD_AU_SCRIPT
Nice=10
EOF
    cat > "$GD_AU_UNIT_DIR/germandactyl-update.timer" <<EOF
[Unit]
Description=GermanDactyl Setup – geplantes Update $(gd_au_day_name "$day") um ${time} Uhr

[Timer]
OnCalendar=${cal}
Persistent=true
RandomizedDelaySec=10min

[Install]
WantedBy=timers.target
EOF
}

gd_autoupdate_enabled() {
    [ -f "$GD_AU_CONF" ] && systemctl is-enabled --quiet germandactyl-update.timer 2>/dev/null
}

gd_autoupdate_setup() {
    # gd_autoupdate_setup <panel> <wings> <reapply> <HH:MM> <daily|Mon..Sun> – einrichten und Timer aktivieren
    gd_autoupdate_write_conf "$1" "$2" "$3" "$4" "$5" || return 1
    gd_autoupdate_write_script || return 1
    gd_autoupdate_write_units "$4" "$5" || return 1
    systemctl daemon-reload
    systemctl enable --now germandactyl-update.timer
}

gd_autoupdate_remove() {
    # Timer, Units, Skript und Einstellungen entfernen (das Log bleibt). Ein "übersprungen" von früher verschwindet aus
    # der Statuszeile; ein "fehlgeschlagen" bleibt stehen, bis das Update gelingt.
    systemctl disable --now germandactyl-update.timer >/dev/null 2>&1
    rm -f "$GD_AU_UNIT_DIR/germandactyl-update.service" "$GD_AU_UNIT_DIR/germandactyl-update.timer" "$GD_AU_SCRIPT" "$GD_AU_CONF"
    systemctl daemon-reload
    [ "$(gd_conf_get LAST_UPDATE_RESULT)" = "uebersprungen" ] && gd_au_clear_result LAST_UPDATE
    [ "$(gd_conf_get LAST_WINGS_UPDATE_RESULT)" = "uebersprungen" ] && gd_au_clear_result LAST_WINGS_UPDATE
    return 0
}

# ---------------------------------------------------------------------------
# Ergebnisse (setup.conf): LAST_UPDATE_* für das Panel, LAST_WINGS_UPDATE_* für Wings
# ---------------------------------------------------------------------------
gd_au_set_result() {
    # gd_au_set_result <LAST_UPDATE|LAST_WINGS_UPDATE> <ok|fehler|uebersprungen> <hinweis> [zielversion]
    gd_conf_set "$1_RESULT" "$2"
    gd_conf_set "$1_TIME" "$(date '+%F %T')"
    gd_conf_set "$1_NOTE" "$3"
    [ -n "${4:-}" ] && gd_conf_set "$1_TARGET" "$4"
    return 0
}

gd_au_clear_result() {
    local k
    for k in RESULT TIME NOTE TARGET; do gd_conf_set "$1_$k" ""; done
}

gd_au_target_failed() {
    # gd_au_target_failed <LAST_UPDATE|LAST_WINGS_UPDATE> <version> – ist genau dieses Update schon einmal fehlgeschlagen?
    # Dann wird es nicht jede Nacht erneut versucht (jeder Versuch bedeutet eine kurze Panel-Pause).
    [ "$(gd_conf_get "$1_RESULT")" = "fehler" ] && [ "$(gd_conf_get "$1_TARGET")" = "$2" ]
}

gd_au_fmt_time() {
    # "2026-10-19 04:31:07" -> "19.10.2026 04:31" (leer bleibt leer)
    [ -n "$1" ] || return 0
    date -d "$1" '+%d.%m.%Y %H:%M' 2>/dev/null || echo "$1"
}

gd_au_result_label() {
    # gd_au_result_label <LAST_UPDATE|LAST_WINGS_UPDATE> -> Text für Status und Menü
    local r t n
    r="$(gd_conf_get "$1_RESULT")"; t="$(gd_conf_get "$1_TIME")"; n="$(gd_conf_get "$1_NOTE")"
    [ -n "$t" ] && t=" ($(gd_au_fmt_time "$t"))"
    case "$r" in
        ok) echo "✔ erfolgreich${t}${n:+ – $n}" ;;
        fehler) echo "✖ fehlgeschlagen${t}${n:+ – $n}" ;;
        uebersprungen) echo "⚠ übersprungen${t}${n:+ – $n}" ;;
        *) echo "noch kein Lauf" ;;
    esac
}

gd_autoupdate_status() {
    # Text für Menü und Analyse (mehrzeilig)
    local next backup state
    if gd_autoupdate_enabled; then state="eingeschaltet"; else state="ausgeschaltet"; fi
    printf 'Automatische Updates: %s\n' "$state"
    if gd_autoupdate_enabled; then
        next="$(systemctl show germandactyl-update.timer -p NextElapseUSecRealtime --value 2>/dev/null | awk '{print $2, $3}')"
        printf 'Zeitplan:        %s um %s Uhr\n' "$(gd_au_day_name "$(gd_au_get DAY daily)")" "$(gd_au_get TIME "$(gd_au_default_time)")"
        printf 'Nächster Lauf:   %s\n' "${next:-unbekannt}"
        printf 'Panel:           %s\n' "$([ "$(gd_au_get PANEL false)" = true ] && echo 'wird aktualisiert' || echo 'nicht automatisch')"
        printf 'Wings:           %s\n' "$([ "$(gd_au_get WINGS false)" = true ] && echo 'wird aktualisiert' || echo 'nicht automatisch')"
        printf 'Eigene Änderungen: %s\n' "$([ "$(gd_au_get REAPPLY false)" = true ] && echo 'werden wieder angewendet' || echo 'Update wird übersprungen')"
        printf 'Letzter Lauf:    %s\n' "$(gd_au_fmt_time "$(gd_conf_get AUTO_UPDATE_LAST_RUN)" | grep . || echo noch keiner)"
    fi
    printf 'Panel-Ergebnis:  %s\n' "$(gd_au_result_label LAST_UPDATE)"
    printf 'Wings-Ergebnis:  %s\n' "$(gd_au_result_label LAST_WINGS_UPDATE)"
    backup="$(gd_conf_get LAST_UPDATE_BACKUP)"
    if [ "$(gd_conf_get LAST_UPDATE_RESULT)" = "fehler" ] && [ -n "$backup" ]; then
        printf 'Sicherung:       %s\n' "$backup"
    fi
    printf 'Log:             %s\n' "$GD_AU_LOG"
}

# ---------------------------------------------------------------------------
# Der eigentliche Lauf (Headless, vom Timer über installer.sh --auto-update gestartet)
# ---------------------------------------------------------------------------
gd_au_log() {
    # Log (GD_LOG, im Headless-Modus ohnehin auto-update.log), Konsole (Journal bzw. "Jetzt ausführen")
    gd_log "$*"
    if [ "${GD_LOG:-}" != "$GD_AU_LOG" ]; then
        mkdir -p "$GD_LOG_DIR"
        echo "[$(date '+%F %T')] $*" >> "$GD_AU_LOG"
    fi
    echo "$*"
}

gd_au_rotate_log() {
    # Das Log wächst mit jedem Lauf: ab 5 MB nur die letzten 3000 Zeilen behalten
    local size tmp
    size="$(stat -c %s "$GD_AU_LOG" 2>/dev/null || echo 0)"
    [ "$size" -gt 5242880 ] || return 0
    tmp="$(mktemp "${GD_TMP:-/tmp}/au-log.XXXXXX")" || return 0
    tail -n 3000 "$GD_AU_LOG" > "$tmp" && cat "$tmp" > "$GD_AU_LOG"
    rm -f "$tmp"
}

gd_au_enough_space() {
    # Mindestens 1 GB frei auf / ? (Sicherung, Download und Composer brauchen Platz)
    local free
    free="$(df -Pk / | awk 'NR==2{print $4}')"
    [ "${free:-0}" -ge 1048576 ]
}

gd_au_list_foreign() {
    # Eigene Änderungen (GD_FOREIGN_FILES, Zeilen oder Array) eingerückt ins Log schreiben, höchstens 20
    local list
    if declare -p GD_FOREIGN_FILES 2>/dev/null | grep -q '^declare -a'; then
        list="$(printf '%s\n' "${GD_FOREIGN_FILES[@]}")"
    else
        list="${GD_FOREIGN_FILES:-}"
    fi
    [ -n "$list" ] || return 0
    head -n 20 <<< "$list" | sed 's/^/    /' | while IFS= read -r l; do gd_au_log "$l"; done
    [ "$(grep -c . <<< "$list")" -gt 20 ] && gd_au_log "    ... und weitere"
    return 0
}

gd_autoupdate_panel() {
    # gd_autoupdate_panel <reapply true/false> – Rückgabe 0 = in Ordnung (auch aktuell/übersprungen), 1 = fehlgeschlagen
    local reapply="$1" installed latest apply=false rc note
    installed="$(gd_panel_installed_version)"
    if [ -z "$installed" ]; then
        gd_au_log "Panel: Die installierte Version ist unbekannt – übersprungen."
        gd_au_set_result LAST_UPDATE uebersprungen "installierte Version unbekannt"
        return 0
    fi
    # Zielversion wie gd_choose_panel_version, aber ohne Dialog: Die Pterodactyl-Version mit deutscher Übersetzung
    latest="$(gd_latest_release pterodactyl/panel)"
    if [ -z "$latest" ]; then
        gd_au_log "Panel: Die neueste Version konnte nicht ermittelt werden (GitHub nicht erreichbar) – übersprungen."
        gd_au_set_result LAST_UPDATE uebersprungen "neueste Version nicht abrufbar (Internet?)"
        return 0
    fi
    if gd_version_ge "$installed" "$latest"; then
        gd_au_log "Panel: v$installed ist aktuell."
        # Ein früheres "übersprungen" ist damit erledigt (z. B. nach einem manuellen Update)
        [ "$(gd_conf_get LAST_UPDATE_RESULT)" = "uebersprungen" ] && gd_au_set_result LAST_UPDATE ok "aktuell (v$installed)"
        return 0
    fi
    if gd_au_target_failed LAST_UPDATE "$latest"; then
        gd_au_log "Panel: Das Update auf v$latest ist schon einmal fehlgeschlagen – es wird nicht automatisch erneut versucht. Führe es manuell aus (Verwaltung → Aktualisieren)."
        return 0
    fi
    if gd_patch_exists "$latest"; then
        apply=true
    elif [ -n "$(gd_conf_get GD_GERMANDACTYL)" ]; then
        gd_au_log "Panel: v$latest ist neu, aber noch ohne deutsche Übersetzung – übersprungen (installiert: v$installed)."
        gd_au_set_result LAST_UPDATE uebersprungen "neue Version v$latest noch ohne deutsche Übersetzung"
        return 0
    fi

    # Eigene Änderungen am Panel (Themes, Plugins, eigene Patches) würden vom Update überschrieben
    gd_panel_detect_changes "$installed" >> "$GD_LOG" 2>&1
    rc=$?
    case "$rc" in
        0) gd_au_log "Panel: Keine eigenen Änderungen erkannt." ;;
        1)
            gd_au_log "Panel: Eigene Änderungen erkannt (${GD_FOREIGN_COUNT:-?} Dateien):"
            gd_au_list_foreign
            if [ "$reapply" != true ]; then
                gd_au_log "Panel: Update auf v$latest übersprungen, damit nichts überschrieben wird."
                gd_au_set_result LAST_UPDATE uebersprungen "eigene Änderungen erkannt: ${GD_FOREIGN_COUNT:-?} Dateien"
                return 0
            fi
            gd_au_log "Panel: Die Änderungen werden nach dem Update wieder angewendet (Einstellung)." ;;
        *)
            gd_au_log "Panel: Die Prüfung auf eigene Änderungen war nicht möglich – übersprungen."
            gd_au_set_result LAST_UPDATE uebersprungen "Prüfung auf eigene Änderungen nicht möglich"
            return 0 ;;
    esac

    if ! gd_au_enough_space; then
        gd_au_log "Panel: Weniger als 1 GB Speicherplatz frei – übersprungen."
        gd_au_set_result LAST_UPDATE uebersprungen "zu wenig Speicherplatz (unter 1 GB frei)"
        return 0
    fi

    gd_au_log "Panel: Update von v$installed auf v$latest startet ($( [ "$apply" = true ] && echo 'mit deutscher Übersetzung' || echo 'ohne Übersetzung'))."
    # In einer Subshell: gd_fail beendet mit "exit 1", das darf den Lauf nicht abbrechen (Wings, Ergebnis eintragen)
    (
        # Steuervariablen für gd_panel_update_steps (lib/panel.sh), dort ausgewertet
        # shellcheck disable=SC2034
        GD_WARNINGS=""
        # shellcheck disable=SC2034
        GD_PANEL_VERSION="$latest"
        # shellcheck disable=SC2034
        GD_APPLY_PATCH="$apply"
        # shellcheck disable=SC2034
        GD_UPDATE_REAPPLY="$reapply"
        # shellcheck disable=SC2034
        GD_UPDATE_BACKUP=true
        # shellcheck disable=SC2034
        GD_UPDATE_AUTO_ROLLBACK=true
        gd_panel_update_steps
    )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        gd_au_log "Panel: Update auf v$latest erfolgreich."
        gd_au_set_result LAST_UPDATE ok "v$installed → v$latest" "$latest"
        gd_conf_set PANEL_LATEST_TS 0
        return 0
    fi
    note="Update auf v$latest fehlgeschlagen (Code $rc)"
    gd_au_log "Panel: $note. Die Sicherung wurde automatisch zurückgespielt, falls sie erstellt werden konnte (Details im Log)."
    gd_au_set_result LAST_UPDATE fehler "$note" "$latest"
    return 1
}

gd_autoupdate_wings() {
    # Rückgabe 0 = in Ordnung (auch aktuell/übersprungen), 1 = fehlgeschlagen
    local latest rc
    latest="$(gd_wings_update_available 2>> "$GD_LOG")"
    rc=$?
    if [ "$rc" -eq 1 ] || { [ "$rc" -eq 0 ] && [ -z "$latest" ]; }; then
        gd_au_log "Wings: ist aktuell."
        [ "$(gd_conf_get LAST_WINGS_UPDATE_RESULT)" = "uebersprungen" ] && gd_au_set_result LAST_WINGS_UPDATE ok "aktuell"
        return 0
    elif [ "$rc" -ne 0 ]; then
        gd_au_log "Wings: Die neueste Version konnte nicht ermittelt werden – übersprungen."
        gd_au_set_result LAST_WINGS_UPDATE uebersprungen "neueste Version nicht abrufbar (Internet?)"
        return 0
    fi
    if gd_au_target_failed LAST_WINGS_UPDATE "$latest"; then
        gd_au_log "Wings: Das Update auf v$latest ist schon einmal fehlgeschlagen – es wird nicht automatisch erneut versucht. Führe es manuell aus (Verwaltung → Aktualisieren)."
        return 0
    fi
    if ! gd_au_enough_space; then
        gd_au_log "Wings: Weniger als 1 GB Speicherplatz frei – übersprungen."
        gd_au_set_result LAST_WINGS_UPDATE uebersprungen "zu wenig Speicherplatz (unter 1 GB frei)"
        return 0
    fi
    gd_au_log "Wings: Update auf v$latest startet."
    ( gd_wings_update_steps )
    rc=$?
    case "$rc" in
        0)
            gd_au_log "Wings: Update auf v$latest erfolgreich."
            gd_au_set_result LAST_WINGS_UPDATE ok "auf v$latest" "$latest"
            gd_conf_set WINGS_LATEST_TS 0
            return 0 ;;
        3)
            gd_au_log "Wings-Update übersprungen: Major-Version passt nicht zum Panel."
            gd_au_set_result LAST_WINGS_UPDATE uebersprungen "Major-Version von v$latest passt nicht zum Panel"
            return 0 ;;
        *)
            gd_au_log "Wings: Update auf v$latest fehlgeschlagen (Code $rc), die vorherige Version wurde wiederhergestellt."
            gd_au_set_result LAST_WINGS_UPDATE fehler "Update auf v$latest fehlgeschlagen" "$latest"
            return 1 ;;
    esac
}

gd_autoupdate_run() {
    # Geplanter Lauf, immer ohne Dialoge. Rückgabe 0 = alles in Ordnung (auch "aktuell"/"übersprungen"), 1 = Fehler.
    local panel wings reapply rc=0 panel_failed=false
    GD_HEADLESS=1
    export GD_HEADLESS
    mkdir -p "$GD_LOG_DIR"
    gd_au_rotate_log
    if [ ! -f "$GD_AU_CONF" ]; then
        gd_au_log "Keine Einstellungen gefunden ($GD_AU_CONF) – automatische Updates sind nicht eingerichtet."
        return 0
    fi
    panel="$(gd_au_get PANEL false)"
    wings="$(gd_au_get WINGS false)"
    reapply="$(gd_au_get REAPPLY false)"

    # Nicht doppelt laufen lassen (Timer und "Jetzt ausführen")
    exec 9> "$GD_AU_LOCK"
    if ! flock -n 9; then
        gd_au_log "Ein Update läuft bereits – übersprungen."
        return 0
    fi
    gd_au_log "=== Automatisches Update gestartet (Panel: $panel, Wings: $wings, eigene Änderungen wieder anwenden: $reapply) ==="

    # Läuft gerade das automatische Backup, dieses abwarten (höchstens 60 Minuten): Ein Backup mitten im Update wäre unbrauchbar
    if [ -e "$GD_AU_BACKUP_LOCK" ]; then
        exec 8> "$GD_AU_BACKUP_LOCK"
        if ! flock -n 8; then
            gd_au_log "Ein Backup läuft gerade – das Update wartet darauf (höchstens 60 Minuten)."
            if ! flock -w 3600 8; then
                gd_au_log "Das Backup lief zu lange – das Update wird übersprungen."
                gd_au_set_result LAST_UPDATE uebersprungen "Backup lief zu lange"
                exec 8>&-
                return 0
            fi
        fi
        exec 8>&-
    fi

    # Zuerst das Panel, dann Wings (Wings 1.x gehört zum Panel 1.x)
    if [ "$panel" = true ] && gd_has_panel; then
        gd_autoupdate_panel "$reapply" || { rc=1; panel_failed=true; }
    fi
    if [ "$wings" = true ] && gd_has_wings; then
        if $panel_failed; then
            gd_au_log "Wings: Das Update wird übersprungen, weil das Panel-Update fehlgeschlagen ist."
        else
            gd_autoupdate_wings || rc=1
        fi
    fi
    gd_conf_set AUTO_UPDATE_LAST_RUN "$(date '+%F %T')"
    if [ "$rc" -eq 0 ]; then gd_au_log "=== Automatisches Update beendet ==="
    else gd_au_log "=== Automatisches Update mit Fehlern beendet ==="; fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
gd_autoupdate_configure() {
    # Fragt Umfang, Umgang mit eigenen Änderungen, Uhrzeit und Wochentag ab (Vorgaben aus der bestehenden Einstellung).
    # Setzt GD_AU_NEW_PANEL, GD_AU_NEW_WINGS, GD_AU_NEW_REAPPLY, GD_AU_NEW_TIME, GD_AU_NEW_DAY. Rückgabe 1 = Abbruch.
    local cur_panel cur_wings cur_reapply cur_time cur_day sel items=() c value
    cur_panel="$(gd_au_get PANEL "$(gd_has_panel && echo true || echo false)")"
    cur_wings="$(gd_au_get WINGS "$(gd_has_wings && echo true || echo false)")"
    cur_reapply="$(gd_au_get REAPPLY false)"
    cur_time="$(gd_au_get TIME "$(gd_au_default_time)")"
    cur_day="$(gd_au_get DAY daily)"

    gd_has_panel && items+=("PANEL" "Pterodactyl Panel (mit deutscher Übersetzung)" "$([ "$cur_panel" = true ] && echo ON || echo OFF)")
    gd_has_wings && items+=("WINGS" "Wings" "$([ "$cur_wings" = true ] && echo ON || echo OFF)")
    if [ ${#items[@]} -eq 0 ]; then
        gd_msg "⏰ Automatische Updates" "Auf diesem Server ist weder das Panel noch Wings installiert – es gibt nichts zu aktualisieren." 9 70
        return 1
    fi
    sel="$(whiptail --title "⏰ Was soll automatisch aktualisiert werden?" --checklist "Leertaste = an/aus. Zuerst wird das Panel aktualisiert, danach Wings." 12 76 ${#items[@]} "${items[@]}" 3>&1 1>&2 2>&3)" || return 1
    GD_AU_NEW_PANEL=false; GD_AU_NEW_WINGS=false
    [[ "$sel" == *'"PANEL"'* ]] && GD_AU_NEW_PANEL=true
    [[ "$sel" == *'"WINGS"'* ]] && GD_AU_NEW_WINGS=true
    if [ "$GD_AU_NEW_PANEL" = false ] && [ "$GD_AU_NEW_WINGS" = false ]; then
        gd_msg "⏰ Automatische Updates" "Es wurde nichts ausgewählt." 8 50
        return 1
    fi

    GD_AU_NEW_REAPPLY=false
    if [ "$GD_AU_NEW_PANEL" = true ]; then
        c="$(whiptail --title "✎ Eigene Änderungen am Panel" --default-item "$([ "$cur_reapply" = true ] && echo reapply || echo skip)" \
            --menu "Vor jedem Update wird geprüft, ob du Dateien des Panels verändert hast (Themes, Plugins, eigene Patches). Was soll dann passieren?" 16 78 2 \
            "skip" "Update überspringen (empfohlen) – du bekommst einen Hinweis" \
            "reapply" "Eigene Änderungen wieder anwenden – sie werden überschrieben" 3>&1 1>&2 2>&3)" || return 1
        [ "$c" = reapply ] && GD_AU_NEW_REAPPLY=true
    fi

    value="$cur_time"
    while true; do
        value="$(gd_input "◷ Uhrzeit" "Um wie viel Uhr sollen die Updates laufen? (Format HH:MM, z. B. 04:30)\n\nDas automatische Backup läuft um $(gd_au_backup_time) Uhr – das Update sollte danach starten. Der Start verschiebt sich zufällig um bis zu 10 Minuten." "$value" 14 72)" || return 1
        value="$(tr -d '[:space:]' <<< "$value")"
        gd_au_valid_time "$value" && break
        gd_msg "Ungültige Uhrzeit" "Bitte gib die Uhrzeit im Format HH:MM an (z. B. 04:30)." 8 60
    done
    GD_AU_NEW_TIME="$value"

    c="$(whiptail --title "◷ Wochentag" --default-item "$cur_day" --menu "An welchen Tagen sollen die Updates laufen?" 18 60 8 \
        "daily" "Jeden Tag" "Mon" "Montags" "Tue" "Dienstags" "Wed" "Mittwochs" "Thu" "Donnerstags" "Fri" "Freitags" "Sat" "Samstags" "Sun" "Sonntags" 3>&1 1>&2 2>&3)" || return 1
    GD_AU_NEW_DAY="$c"
    GD_AU_NEW_LABEL="$(gd_au_day_name "$GD_AU_NEW_DAY") um $GD_AU_NEW_TIME Uhr"
    return 0
}

gd_autoupdate_apply() {
    # gd_autoupdate_apply <einrichten|ändern> – schreibt die abgefragten Einstellungen (GD_AU_NEW_*) und meldet das Ergebnis
    local text
    text="Panel:  $([ "$GD_AU_NEW_PANEL" = true ] && echo ja || echo nein)\nWings:  $([ "$GD_AU_NEW_WINGS" = true ] && echo ja || echo nein)\nEigene Änderungen: $([ "$GD_AU_NEW_REAPPLY" = true ] && echo 'wieder anwenden' || echo 'Update überspringen')\nZeitplan: ${GD_AU_NEW_LABEL}\n\nVor jedem Panel-Update wird eine Sicherung erstellt; schlägt es fehl, wird sie automatisch zurückgespielt. Ergebnisse siehst du in der Statuszeile des Hauptmenüs und beim Login."
    gd_yesno "⏰ Automatische Updates ${1}" "$text\n\nSo speichern?" 17 76 || return 1
    clear; echo "Automatische Updates werden eingerichtet..."
    if gd_autoupdate_setup "$GD_AU_NEW_PANEL" "$GD_AU_NEW_WINGS" "$GD_AU_NEW_REAPPLY" "$GD_AU_NEW_TIME" "$GD_AU_NEW_DAY" >> "$GD_LOG" 2>&1; then
        gd_msg "✔ Automatische Updates" "Gespeichert: ${GD_AU_NEW_LABEL}.\n\nNächster Lauf: $(systemctl show germandactyl-update.timer -p NextElapseUSecRealtime --value 2>/dev/null | awk '{print $2, $3}' | grep . || echo unbekannt)" 11 70
    else
        gd_msg "✖ Fehler" "Die automatischen Updates konnten nicht eingerichtet werden. Details: $GD_LOG" 9 70
        return 1
    fi
}

gd_autoupdate_activate() {
    # Einschalten: erst die rote Warnung (Standard: Nein), dann die Einstellungen
    local rc
    gd_warn_colors_on
    gd_whip --title "⚠ Automatische Updates einschalten?" --defaultno --yesno "Automatische Updates überschreiben eigene Änderungen am Panel (Themes, Plugins, eigene Patches). Vor jedem Update wird eine Sicherung erstellt; schlägt das Update fehl, wird sie automatisch zurückgespielt. Erkennt die Prüfung eigene Änderungen, wird das Update übersprungen – außer du wählst 'eigene Änderungen wieder anwenden'.\n\nWährend des Updates ist das Panel einige Minuten nicht erreichbar.\n\nMöchtest du automatische Updates trotzdem einschalten?" 20 76
    rc=$?
    gd_warn_colors_off
    [ "$rc" -eq 0 ] || return 1
    gd_autoupdate_configure || return 1
    gd_autoupdate_apply einrichten
}

gd_autoupdate_run_now() {
    gd_yesno "➜ Jetzt ausführen" "Das Update läuft jetzt sofort im Vordergrund, mit denselben Regeln wie der geplante Lauf (Sicherung vorher, Zurückspielen bei Fehlern, Überspringen bei eigenen Änderungen).\n\nDas Panel ist währenddessen einige Minuten nicht erreichbar.\n\nJetzt ausführen?" 14 74 || return 0
    [ -x "$GD_AU_SCRIPT" ] || gd_autoupdate_write_script
    clear
    echo "Geplantes Update wird jetzt ausgeführt (Log: $GD_AU_LOG)..."
    echo ""
    # Eigene Arbeitsumgebung: GD_TMP/GD_LOG dieser Sitzung dürfen vom Update-Lauf nicht übernommen (und gelöscht) werden
    local rc
    env -u GD_TMP -u GD_LOG -u GD_LIB_DIR -u GD_LOCAL_DIR "$GD_AU_SCRIPT"
    rc=$?
    echo ""
    echo "Fertig (Rückgabecode $rc). Drücke Enter, um zum Menü zurückzukehren."
    read -r _ < /dev/tty
    gd_conf_set PANEL_LATEST_TS 0
    gd_conf_set WINGS_LATEST_TS 0
    gd_msg "➜ Ergebnis" "$(gd_autoupdate_status | sed -n '/^Panel-Ergebnis/,$p')" 12 78
}

gd_autoupdate_disable() {
    gd_yesno "✖ Automatische Updates ausschalten" "Panel und Wings werden danach nicht mehr automatisch aktualisiert. Du kannst sie jederzeit unter 'Aktualisieren' selbst aktualisieren.\n\nAusschalten?" 11 70 || return 0
    gd_autoupdate_remove >> "$GD_LOG" 2>&1
    gd_msg "Ausgeschaltet" "Die automatischen Updates sind ausgeschaltet." 8 60
}

gd_autoupdate_menu() {
    local c
    while true; do
        if gd_autoupdate_enabled; then
            c="$(gd_submenu "⏰ Automatische Updates" "Eingeschaltet: $(gd_au_day_name "$(gd_au_get DAY daily)") um $(gd_au_get TIME "$(gd_au_default_time)") Uhr" \
                "1" "☰ Status anzeigen" \
                "2" "⚙ Einstellungen ändern" \
                "3" "➜ Jetzt ausführen" \
                "4" "✖ Ausschalten")" || return
            case "$c" in
                1) gd_msg "☰ Automatische Updates" "$(gd_autoupdate_status)" 20 78 ;;
                2) gd_autoupdate_configure && gd_autoupdate_apply ändern ;;
                3) gd_autoupdate_run_now ;;
                4) gd_autoupdate_disable ;;
                *) return ;;
            esac
        else
            c="$(gd_submenu "⏰ Automatische Updates" "Ausgeschaltet. Geplante Updates sind standardmäßig aus und überschreiben beim Einschalten eigene Änderungen am Panel." \
                "1" "✔ Einschalten (mit Hinweis)" \
                "2" "☰ Letztes Ergebnis anzeigen")" || return
            case "$c" in
                1) gd_autoupdate_activate ;;
                2) gd_msg "☰ Automatische Updates" "$(gd_autoupdate_status)" 14 78 ;;
                *) return ;;
            esac
        fi
    done
}
