#!/bin/bash
# Pfad: tests/test_manage.sh
# Tests für lib/manage.sh: Bereinigung des Support-Pakets (gd_sanitize), Textfassung (gd_support_text), Hilfetext und
# Unterbefehle (gd_dispatch mit Befehlen, die nichts verändern), sowie die Firewall-Bereinigung der Deinstallation
# (gd_uninstall_dbhost_firewall in lib/uninstall.sh, mit ufw-Attrappe).
# Die Funktionen werden per t_fn aus den Dateien herausgelöst. Wird von tests/run.sh eingebunden (nicht einzeln ausführen).

t_group "manage.sh: Funktionen herauslösen"
for _fn in gd_sanitize gd_support_section gd_support_text gd_shortcut_name gd_shortcut_hint gd_shortcut_help_text gd_dispatch; do
    t_fn lib/manage.sh "$_fn" && t_ok "Funktion $_fn geladen" declare -F "$_fn"
done
t_fn lib/uninstall.sh gd_uninstall_dbhost_firewall && t_ok "Funktion gd_uninstall_dbhost_firewall geladen" declare -F gd_uninstall_dbhost_firewall
unset _fn

# Hilfsfunktion: Text durch gd_sanitize schicken (über eine Datei, wie im Support-Paket)
_san() {
    printf '%s\n' "$1" > "$GD_TMP/san-test.txt"
    gd_sanitize "$GD_TMP/san-test.txt"
    cat "$GD_TMP/san-test.txt"
}
_contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------------------
t_group "gd_sanitize: Bestehende Regeln"
t_eq "Passwort-Zeile (Schlüssel=Wert)"       "DB_PASSWORD=***"          "$(_san 'DB_PASSWORD=geheim')"
t_eq "APP_KEY mit base64-Wert"               "APP_KEY=***"              "$(_san 'APP_KEY=base64:abc+def/ghi=')"
t_eq "Bearer-Token"                          "Authorization: Bearer ***" "$(_san 'Authorization: Bearer abc.def-ghi')"
t_eq "Panel-API-Schlüssel (ptla_)"           "ptla_***"                 "$(_san 'ptla_AbCdEf123')"

t_group "gd_sanitize: Neue Regeln"
t_eq "E-Mail-Adresse wird ersetzt"           "Kontakt: ***@***"         "$(_san 'Kontakt: admin@example.de')"
t_eq "Zeile ohne Geheimnisse bleibt"         "Panel: panel.example.de (v1.2.3)" "$(_san 'Panel: panel.example.de (v1.2.3)')"
t_eq "Hex-Wert ab 32 Zeichen"                "id: ***"                  "$(_san 'id: 0123456789abcdef0123456789abcdef')"
t_eq "kürzerer Hex-Wert bleibt"              "sha: 0123456789abcdef"    "$(_san 'sha: 0123456789abcdef')"
t_eq "Cloudflare-Token (certbot-Datei)"      "dns_cloudflare_api_token = ***" "$(_san 'dns_cloudflare_api_token = AbC123_xyz-987')"
t_eq "RESTIC_PASSWORD"                       "RESTIC_PASSWORD=***"      "$(_san 'RESTIC_PASSWORD=geheim')"
t_eq "AWS_SECRET_ACCESS_KEY"                 "AWS_SECRET_ACCESS_KEY=***" "$(_san 'AWS_SECRET_ACCESS_KEY=abc123')"
t_eq "Passwort in der URL (sftp)"            "sftp://backup:***@storage.example.de/repo" "$(_san 'sftp://backup:Geheim123@storage.example.de/repo')"
t_eq "sshpass -p"                            "sshpass -p *** ssh host"  "$(_san 'sshpass -p Geheim ssh host')"

# ---------------------------------------------------------------------------
t_group "gd_support_text: Abschnitte und Kürzung"
_sup="$GD_TMP/support-test"
rm -rf "$_sup"; mkdir -p "$_sup"
printf 'Panel:     1.11.2\n' > "$_sup/versionen.txt"
printf 'l1\nl2\nl3\nl4\n' > "$_sup/panel.log"
gd_support_text "$_sup" "$GD_TMP/support-test.txt" 2
t_ok "Abschnitt Versionen vorhanden" grep -qxF '===== Versionen =====' "$GD_TMP/support-test.txt"
t_ok "Abschnitt Log mit Anzahl der Zeilen" grep -qxF '===== Log: panel.log (letzte 2 Zeilen) =====' "$GD_TMP/support-test.txt"
t_ok "Log zeigt die letzte Zeile" grep -qxF 'l4' "$GD_TMP/support-test.txt"
t_no "Log kürzt ältere Zeilen" grep -qxF 'l1' "$GD_TMP/support-test.txt"
t_ok "fehlende Datei wird vermerkt" grep -qxF '(keine Angaben)' "$GD_TMP/support-test.txt"
unset _sup

# ---------------------------------------------------------------------------
t_group "Kurzbefehle: Hilfe und unbekannte Befehle"
_help="$(gd_dispatch hilfe 2>/dev/null)"
t_ok "Hilfe nennt support" _contains "$_help" "support"
t_ok "Hilfe nennt dbhost-sync" _contains "$_help" "dbhost-sync"
t_no "unbekannter Befehl liefert Fehler" gd_dispatch gibt-es-nicht
unset _help

# ---------------------------------------------------------------------------
t_group "Deinstallation: Firewall-Regeln je Node"
# ufw-Attrappe: Panel, zwei Nodes und eine Fremdregel (Gameserver-Port, soll stehen bleiben)
gd_ufw_active() { return 0; }
ufw() {
    if [ "$1" = status ]; then
        cat <<'UFW'
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 3306/tcp                   ALLOW IN    10.0.0.5                   # MariaDB (Panel)
[ 2] 3306/tcp                   ALLOW IN    203.0.113.7                # MariaDB (Node node1.example.de)
[ 3] 25565/tcp                  ALLOW IN    Anywhere                   # Gameserver
[ 4] 3306/tcp                   ALLOW IN    198.51.100.9               # MariaDB (Node node2.example.de)
UFW
    elif [ "$1" = --force ] && [ "$2" = delete ]; then
        echo "$3" >> "$GD_TMP/ufw-deleted"
    fi
}
rm -f "$GD_TMP/ufw-deleted"
gd_uninstall_dbhost_firewall >/dev/null 2>&1
t_eq "Panel- und Node-Regeln entfernt, von hinten nach vorn" "4 2 1" "$(tr '\n' ' ' < "$GD_TMP/ufw-deleted" 2>/dev/null | sed 's/ $//')"
unset -f ufw gd_ufw_active
rm -f "$GD_TMP/ufw-deleted"
