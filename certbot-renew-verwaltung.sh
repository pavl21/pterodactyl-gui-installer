#!/bin/bash
# Pfad: certbot-renew-verwaltung.sh
# SSL-Zertifikate: Status, Erneuerung testen, fällige Zertifikate erneuern, Zertifikat erzwungen neu ausstellen,
# automatische Erneuerung einrichten. Webserver laufen dabei weiter; nach einer Erneuerung werden nginx und Wings
# über den Deploy-Hook (lib/security.sh) automatisch neu geladen bzw. neu gestartet.

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
gd_source_lib security

if ! command -v certbot >/dev/null 2>&1; then
    gd_msg "Certbot fehlt" "Certbot ist auf diesem Server nicht installiert, es gibt also keine Let's-Encrypt-Zertifikate zu erneuern." 9 70
    exit 0
fi

# Verzeichnis von certbot (per Umgebungsvariable überschreibbar, z. B. für Tests)
LE_DIR="${GD_LE_DIR:-/etc/letsencrypt}"
HOOK_LOG="$GD_LOG_DIR/certbot-hook.log"

# ---------------------------------------------------------------------------
# Zertifikate auflisten und beschreiben
# ---------------------------------------------------------------------------
cert_names() {
    # Namen aller Zertifikate: aus den Erneuerungskonfigurationen und den Ordnern unter live (Reihenfolge: alphabetisch).
    # Nur harmlose Zeichen zulassen – die Namen landen in Befehlen und Dateinamen.
    local c
    {
        for c in "$LE_DIR"/renewal/*.conf; do [ -f "$c" ] && basename "$c" .conf; done
        for c in "$LE_DIR"/live/*/fullchain.pem; do [ -f "$c" ] && basename "$(dirname "$c")"; done
    } | grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*$' | sort -u
}

conf_get() {
    # conf_get <name> <schlüssel> – Wert aus der Erneuerungskonfiguration (Kopf und [renewalparams])
    local conf="$LE_DIR/renewal/$1.conf"
    [ -f "$conf" ] || return 0
    awk -v k="$2" '
        /^[[:space:]]*\[\[/ { sec = 2; next }
        /^[[:space:]]*\[/ { sec = ($0 ~ /^[[:space:]]*\[renewalparams\]/) ? 1 : 2; next }
        /^[[:space:]]*#/ { next }
        sec != 2 {
            i = index($0, "="); if (i == 0) next
            key = substr($0, 1, i - 1); gsub(/[[:space:]]/, "", key)
            if (key != k) next
            val = substr($0, i + 1); sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
            print val; exit
        }' "$conf"
}

days_text() {
    # days_text <tage> – Restlaufzeit in Worten (negativ = abgelaufen)
    if [ "$1" -lt 0 ]; then
        [ "$1" -eq -1 ] && echo "abgelaufen seit 1 Tag" || echo "abgelaufen seit $(( -$1 )) Tagen"
    elif [ "$1" -eq 0 ]; then echo "läuft heute ab"
    elif [ "$1" -eq 1 ]; then echo "noch 1 Tag"
    else echo "noch $1 Tage"; fi
}

renew_threshold_days() {
    # renew_threshold_days <datei> <name> – darunter hätte certbot das Zertifikat längst erneuern müssen: ein Drittel der
    # Laufzeit (90 Tage -> 30 Tage) abzüglich 5 Tage Puffer; eine eigene Einstellung (renew_before_expiry) zählt auch.
    local rb s e se ee thr=25
    rb="$(conf_get "$2" renew_before_expiry)"
    if [[ "$rb" =~ ^([0-9]+)[[:space:]]*days?$ ]]; then
        thr=$(( BASH_REMATCH[1] - 5 ))
    else
        s="$(openssl x509 -noout -startdate -in "$1" 2>/dev/null | cut -d= -f2)"
        e="$(openssl x509 -noout -enddate -in "$1" 2>/dev/null | cut -d= -f2)"
        se="$(date -d "$s" +%s 2>/dev/null)"; ee="$(date -d "$e" +%s 2>/dev/null)"
        if [[ "$se" =~ ^[0-9]+$ && "$ee" =~ ^[0-9]+$ ]]; then
            thr=$(( (ee - se) / 86400 / 3 - 5 ))
            [ "$thr" -gt 25 ] && thr=25
        fi
    fi
    [ "$thr" -lt 1 ] && thr=1
    echo "$thr"
}

is_staging() {
    # Zertifikat aus der Let's-Encrypt-Testumgebung? (Browser vertrauen ihm nicht)
    openssl x509 -noout -issuer -in "$1" 2>/dev/null | grep -qiE 'STAGING|Fake LE'
}

timer_state() {
    # Gibt eine Beschreibung des Erneuerungs-Timers aus; Rückgabe 0 = läuft, 1 = eingerichtet aber gestoppt, 2 = fehlt
    local t active enabled
    for t in certbot.timer snap.certbot.renew.timer; do
        systemctl cat "$t" >/dev/null 2>&1 || continue
        active="inaktiv"; enabled="beim Systemstart aus"
        systemctl is-active --quiet "$t" 2>/dev/null && active="aktiv"
        systemctl is-enabled --quiet "$t" 2>/dev/null && enabled="beim Systemstart an"
        echo "$t: $active ($enabled)"
        [ "$active" = "aktiv" ] && return 0 || return 1
    done
    if [ ! -d /run/systemd/system ] && [ -f /etc/cron.d/certbot ]; then
        echo "Cronjob /etc/cron.d/certbot (ohne systemd)"; return 0
    fi
    echo "fehlt (kein certbot.timer gefunden)"
    return 2
}

days_overview() {
    # Eine Zeile je Zertifikat mit Restlaufzeit
    local n days
    for n in $(cert_names); do
        days="$(gd_cert_days_left "$LE_DIR/live/$n/fullchain.pem" 2>/dev/null)" || continue
        echo "• $n: $(days_text "$days")"
    done
}

show_status() {
    local out="$GD_TMP/zertifikate-status.txt" n file days auth sym tag names overdue=false state
    names="$(cert_names)"
    {
        if [ -z "$names" ]; then
            echo "Es wurden keine Zertifikate gefunden."
        else
            printf '    %-36s %-26s %s\n' "Zertifikat" "Restlaufzeit" "Methode"
            for n in $names; do
                file="$LE_DIR/live/$n/fullchain.pem"
                auth="$(conf_get "$n" authenticator)"
                tag=""
                if [ ! -f "$LE_DIR/renewal/$n.conf" ]; then
                    tag="  (keine Erneuerungskonfiguration – wird nicht erneuert)"
                    auth="–"
                fi
                if days="$(gd_cert_days_left "$file" 2>/dev/null)"; then
                    # certbot erneuert ab 30 Tagen; bleibt deutlich weniger übrig, hat die automatische Erneuerung offenbar versagt
                    if [ "$days" -lt 0 ]; then sym="✖"; overdue=true
                    elif [ "$days" -lt "$(renew_threshold_days "$file" "$n")" ]; then sym="⚠"; overdue=true
                    else sym="✔"; fi
                    is_staging "$file" && tag="$tag  [Test-Zertifikat (Staging), Browser vertrauen ihm nicht]"
                    printf '%s   %-36s %-26s %s%s\n' "$sym" "$n" "$(days_text "$days")" "${auth:-–}" "$tag"
                else
                    printf '✖   %-36s %-26s %s%s\n' "$n" "Zertifikat fehlt/unlesbar" "${auth:-–}" "$tag"
                    overdue=true
                fi
            done
            $overdue && printf '\n⚠ certbot erneuert ab 30 Tagen Restlaufzeit. Steht hier weniger, funktioniert die\n  automatische Erneuerung nicht – prüfe sie mit "Erneuerung testen".\n'
        fi
        echo ""
        state="$(timer_state)"
        echo "Automatische Erneuerung: $state"
        if [ -x "$LE_DIR/renewal-hooks/deploy/germandactyl.sh" ]; then
            echo "Deploy-Hook (nginx/Wings neu laden): vorhanden"
        else
            echo "Deploy-Hook (nginx/Wings neu laden): fehlt – Punkt 5 legt ihn an"
        fi
    } > "$out"
    gd_whip --title "✱ SSL-Zertifikate – Status" --scrolltext --textbox "$out" 22 100
}

# ---------------------------------------------------------------------------
# Erneuerung auswerten
# ---------------------------------------------------------------------------
split_renew_output() {
    # split_renew_output <ausgabe> <ordner> – zerlegt die Ausgabe von "certbot renew" in
    #   <ordner>/names       Zertifikate in der Reihenfolge der Verarbeitung
    #   <ordner>/<name>.blk  Ausgabe je Zertifikat (für die Fehlerursache)
    #   <ordner>/results     "name<TAB>success|failure|skipped" aus der Zusammenfassung von certbot
    awk -v dir="$2" '
        {
            lc = tolower($0)
            # Ab der Zusammenfassung gehören die Zeilen zu keinem Zertifikat mehr
            if (lc ~ /^(\*\* dry run|congratulations, all|all (simulated )?renewals|the following|no renewals were attempted|[0-9]+ renew failure)/) cur = ""
            if (lc ~ /processing .*\/renewal\/[^\/ ]+\.conf/) {
                match($0, /renewal\/[^\/ ]+\.conf/)
                cur = substr($0, RSTART + 8, RLENGTH - 13)
                if (cur !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) cur = ""
                else print cur >> (dir "/names")
            }
            if (cur != "") print $0 >> (dir "/" cur ".blk")
            if (match($0, /\/live\/[^\/ ]+\/fullchain\.pem[^()]*\((success|failure|skipped)\)/)) {
                s = substr($0, RSTART, RLENGTH)
                n = s; sub(/^\/live\//, "", n); sub(/\/.*/, "", n)
                r = s; sub(/.*\(/, "", r); sub(/\)$/, "", r)
                print n "\t" r >> (dir "/results")
            }
        }' "$1"
}

cert_cause() {
    # cert_cause <name> <blockdatei> – Fehlerursache in verständlichen Worten (Gross-/Kleinschreibung egal)
    local name="$1" blk="$2" auth detail
    auth="$(conf_get "$name" authenticator)"
    if [ ! -f "$blk" ]; then echo "keine Details im Protokoll"; return; fi
    if grep -qiE 'could not bind|address already in use' "$blk"; then
        echo "Port 80 ist belegt: Das Zertifikat wurde im 'standalone'-Modus erstellt, während jetzt ein Webserver läuft. Stelle die Erneuerung auf nginx/webroot um (Hilfe & Analyse → Analyse starten → Probleme beheben)."
    elif grep -qiE 'ratelimited|too many (certificates|failed|new orders|requests)|rate limit' "$blk"; then
        echo "Das Limit von Let's Encrypt wurde erreicht. Warte einige Stunden und versuche es erneut (bei Duplikaten bis zu einer Woche)."
    elif [ "$auth" = "dns-cloudflare" ] && grep -qiE 'cloudflare|api token|authentication error|invalid request headers|credentials|zone|dns problem' "$blk"; then
        echo "Die DNS-Prüfung über Cloudflare ist fehlgeschlagen: Prüfe den API-Token in $LE_DIR/cloudflare.ini (Rechte Zone:DNS:Edit und Zone:Zone:Read) und ob die Domain in diesem Cloudflare-Konto liegt."
    elif grep -qiE 'plugin.*(not|nicht).*(install|found)|requested .* plugin does not appear' "$blk"; then
        echo "Das nötige certbot-Plugin ist nicht installiert (z. B. python3-certbot-nginx oder python3-certbot-dns-cloudflare)."
    elif grep -qiE 'webroot.*(does not exist|not a directory)|(does not exist|not a directory).*webroot' "$blk"; then
        echo "Das webroot-Verzeichnis aus der Erneuerungskonfiguration existiert nicht."
    elif grep -qiE 'dns problem|nxdomain|no valid ip|unauthorized|invalid response|timeout during connect|connection refused|connection reset|firewall' "$blk"; then
        echo "Let's Encrypt erreicht diesen Server über die Domain nicht: Die Domain zeigt nicht (mehr) auf diesen Server, Port 80 ist gesperrt oder ein Proxy (z. B. Cloudflare) ist davor geschaltet."
    else
        detail="$(grep -iE -m1 'detail:' "$blk" | sed -E 's/^.*[Dd]etail: *//')"
        [ -z "$detail" ] && detail="$(sed -nE 's/.*with error: *//p' "$blk" | head -n1)"
        [ -z "$detail" ] && detail="$(grep -iE -m1 'error|failed' "$blk")"
        detail="${detail//\\/}"
        echo "${detail:0:160}"
    fi
}

report_renew() {
    # report_renew <dry|real> <ausgabedatei> <rückgabecode> – zeigt das Ergebnis je Zertifikat an
    local mode="$1" out="$2" rc="$3" dir n res blk names lines="" nfail=0 title text="" extra=""
    dir="$(mktemp -d "${GD_TMP:-/tmp}/renew.XXXXXX")" || return 1
    split_renew_output "$out" "$dir"
    names=""
    [ -f "$dir/names" ] && names="$(awk '!seen[$0]++' "$dir/names")"
    for n in $names; do
        res="$(awk -F'\t' -v n="$n" '$1 == n { r = $2 } END { print r }' "$dir/results" 2>/dev/null)"
        blk="$dir/$n.blk"
        # Fehlt die Zusammenfassung, zählt ein Fehler in der Ausgabe des Zertifikats
        if [ -z "$res" ] && [ -f "$blk" ] && grep -qiE 'failed to renew|renew failure|unexpected error' "$blk"; then res="failure"; fi
        case "$res" in
            failure) nfail=$((nfail + 1)); lines+="✖ ${n}\n   $(cert_cause "$n" "$blk")\n" ;;
            skipped) lines+="• ${n}: noch nicht fällig, nichts zu tun\n" ;;
            success)
                if [ "$mode" = "dry" ]; then lines+="✔ ${n}: Erneuerung würde funktionieren\n"
                else lines+="✔ ${n}: erfolgreich erneuert\n"; fi ;;
            *) lines+="? ${n}: kein Ergebnis im Protokoll (Log: $GD_LOG)\n" ;;
        esac
    done
    # Fehler, die sich keinem Zertifikat zuordnen ließen (z. B. certbot läuft bereits, Konfigurationsfehler)
    if [ -z "$names" ] || { [ "$nfail" -eq 0 ] && grep -qiE 'failed to renew|renew failure|could not be renewed|\(failure\)' "$out"; }; then
        if grep -qi 'another instance of certbot' "$out"; then
            lines+="✖ Ein anderer certbot-Prozess läuft gerade. Warte kurz und versuche es erneut.\n"; nfail=$((nfail + 1))
        elif [ "$rc" -eq 124 ]; then
            lines+="✖ Die Erneuerung hat zu lange gedauert und wurde abgebrochen (Netzwerk oder Let's Encrypt nicht erreichbar?).\n"; nfail=$((nfail + 1))
        elif [ -z "$names" ] && grep -qi 'no renewals were attempted' "$out"; then
            lines+="Es gibt keine Zertifikate, die certbot erneuern könnte.\n"
        elif [ "$rc" -ne 0 ] || [ -z "$names" ]; then
            extra="$(grep -iE -m1 'error|fail|could not|unable' "$out")"
            [ -z "$extra" ] && extra="$(tail -n 1 "$out")"
            lines+="✖ certbot meldet einen Fehler: $(cut -c1-110 <<< "${extra//\\/}")\n"; nfail=$((nfail + 1))
        fi
    fi
    if [ "$nfail" -gt 0 ]; then title="⚠ Probleme bei der Erneuerung"; text="Mindestens ein Zertifikat konnte nicht erneuert werden:\n\n"
    elif [ "$mode" = "dry" ]; then title="✔ Erneuerung funktioniert"; text="Der Testlauf war erfolgreich. Die automatische Erneuerung sollte rechtzeitig funktionieren.\n\n"
    else title="✔ Erneuerung abgeschlossen"; text="Es wurden keine Probleme festgestellt.\n\n"; fi
    text+="$lines"
    if [ "$mode" != "dry" ]; then
        extra="$(days_overview)"
        [ -n "$extra" ] && text+="\nRestlaufzeiten:\n$(printf '%s\\n' "$extra")"
        text+="\nnginx und Wings werden nach einer Erneuerung vom Deploy-Hook neu geladen (Protokoll: $HOOK_LOG)."
    fi
    [ "$nfail" -gt 0 ] && text+="\nDas vollständige Protokoll: $GD_LOG und /var/log/letsencrypt/letsencrypt.log"
    rm -rf "$dir"
    gd_msg "$title" "$text" 24 94
}

run_renew() {
    # run_renew <dry|real|force> [zertifikatsname] – certbot ausführen, Ausgabe ins Log, Ergebnis anzeigen
    local mode="$1" name="${2:-}" out="$GD_TMP/renew-output.txt" rc args=()
    case "$mode" in
        # Testlauf gegen die Testumgebung (kein Limit). Die Hooks im Verzeichnis renewal-hooks werden dabei nicht
        # ausgeführt: Ein Test soll weder nginx neu laden noch Wings neu starten.
        dry) args=(renew --dry-run --no-directory-hooks) ;;
        real) args=(renew) ;;
        force) args=(renew --cert-name "$name" --force-renewal) ;;
        *) return 1 ;;
    esac
    clear
    case "$mode" in
        dry) echo "Erneuerung wird getestet (das kann eine Minute dauern)..." ;;
        force) echo "Zertifikat $name wird neu ausgestellt..." ;;
        *) echo "Zertifikate werden geprüft und bei Bedarf erneuert..." ;;
    esac
    timeout 900 certbot "${args[@]}" --non-interactive > "$out" 2>&1
    rc=$?
    { echo "== certbot ${args[*]}"; cat "$out"; } >> "$GD_LOG"
    report_renew "$([ "$mode" = "dry" ] && echo dry || echo real)" "$out" "$rc"
}

# ---------------------------------------------------------------------------
# Menüpunkte
# ---------------------------------------------------------------------------
force_renew() {
    local items=() n days auth sel rc
    for n in $(cert_names); do
        # Ohne Erneuerungskonfiguration kennt certbot das Zertifikat nicht – es lässt sich nicht erneuern
        [ -f "$LE_DIR/renewal/$n.conf" ] || continue
        auth="$(conf_get "$n" authenticator)"
        if days="$(gd_cert_days_left "$LE_DIR/live/$n/fullchain.pem" 2>/dev/null)"; then
            items+=("$n" "$(days_text "$days") – ${auth:-?}")
        else
            items+=("$n" "Zertifikat fehlt – ${auth:-?}")
        fi
    done
    if [ ${#items[@]} -eq 0 ]; then
        gd_msg "Keine Zertifikate" "Es gibt kein Zertifikat, das certbot neu ausstellen könnte." 8 66
        return
    fi
    sel="$(whiptail --title "✚ Zertifikat neu ausstellen" --menu "Welches Zertifikat soll erzwungen neu ausgestellt werden?" 18 76 $(( ${#items[@]} / 2 )) "${items[@]}" 3>&1 1>&2 2>&3)" || return
    gd_warn_colors_on
    gd_whip --title "⚠ Limit von Let's Encrypt" --defaultno --yesno "Das Zertifikat $sel wird jetzt sofort neu bei Let's Encrypt angefordert, auch wenn es noch lange gültig ist.\n\nDas verbraucht das Limit von 5 Duplikaten pro Woche. Ist es erreicht, lässt sich für diese Domain eine Woche lang kein weiteres Zertifikat ausstellen.\n\nMeistens genügt 'Erneuerung testen' oder 'Jetzt erneuern'. Erzwingen ist nur nötig, wenn das Zertifikat beschädigt ist oder sich die Domains geändert haben.\n\nWirklich neu ausstellen?" 19 74
    rc=$?
    gd_warn_colors_off
    [ $rc -eq 0 ] || return
    run_renew force "$sel"
}

setup_auto_renewal() {
    local text="" state rc n next
    clear
    echo "Automatische Erneuerung wird eingerichtet..."
    # Fehlt der Timer, kommt er mit dem Paket (Debian/Ubuntu); bei Snap-Installationen gibt es einen eigenen Timer
    if ! systemctl cat certbot.timer >/dev/null 2>&1 && ! systemctl cat snap.certbot.renew.timer >/dev/null 2>&1 \
        && [ -d /run/systemd/system ]; then
        gd_apt_install certbot >> "$GD_LOG" 2>&1
    fi
    if systemctl cat certbot.timer >/dev/null 2>&1; then
        systemctl enable --now certbot.timer >> "$GD_LOG" 2>&1
    elif systemctl cat snap.certbot.renew.timer >/dev/null 2>&1; then
        systemctl enable --now snap.certbot.renew.timer >> "$GD_LOG" 2>&1
    fi
    gd_certbot_hook >> "$GD_LOG" 2>&1
    state="$(timer_state)"; rc=$?
    case $rc in
        0) text+="✔ Timer: $state\n" ;;
        1) text+="✖ Timer: $state – er konnte nicht gestartet werden (Details im Log: $GD_LOG)\n" ;;
        *) text+="✖ Timer: $state\n   certbot ist offenbar nicht über apt oder snap installiert. Installiere das Paket 'certbot', dann bringt es den Timer mit.\n" ;;
    esac
    next="$(systemctl show certbot.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
    [ -z "$next" ] && next="$(systemctl show snap.certbot.renew.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
    [ -n "$next" ] && text+="   Nächster Lauf: $next\n"
    if [ -x "$LE_DIR/renewal-hooks/deploy/germandactyl.sh" ]; then
        text+="✔ Deploy-Hook ist angelegt: nginx wird nach einer Erneuerung neu geladen (nur mit gültiger Konfiguration), Wings bei Bedarf neu gestartet.\n"
    else
        text+="✖ Der Deploy-Hook konnte nicht angelegt werden.\n"
    fi
    for n in $(cert_names); do
        [ -f "$LE_DIR/renewal/$n.conf" ] || text+="⚠ $n: keine Erneuerungskonfiguration – certbot erneuert dieses Zertifikat nicht\n"
    done
    text+="\nOb die Erneuerung wirklich funktioniert, prüft 'Erneuerung testen'."
    gd_msg "✱ Automatische Erneuerung" "$text" 18 84
}

certs_menu() {
    local choice
    while true; do
        choice=$(whiptail --title "✱ SSL-Zertifikate" --menu "Was möchtest du tun?" 18 78 6 \
            "1" "☰ Status anzeigen" \
            "2" "⚙ Erneuerung testen (Dry-Run, ohne Limits)" \
            "3" "✱ Jetzt erneuern (nur fällige)" \
            "4" "✚ Zertifikat neu ausstellen (erzwungen)" \
            "5" "⚙ Automatische Erneuerung einrichten/prüfen" \
            "6" "← Zurück" 3>&1 1>&2 2>&3) || return 0
        case "$choice" in
            1) show_status ;;
            2) run_renew dry ;;
            3) run_renew real ;;
            4) force_renew ;;
            5) setup_auto_renewal ;;
            *) return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------
# Deploy-Hook sicherstellen (ältere Installationen hatten keinen oder einen veralteten)
gd_certbot_hook
certs_menu
