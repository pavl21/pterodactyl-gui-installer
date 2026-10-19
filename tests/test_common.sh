#!/bin/bash
# Pfad: tests/test_common.sh
# Tests für lib/common.sh: Versionsvergleich, IP/CIDR/Cloudflare, Validierung, .env, Konfiguration, Passwörter.
# Wird von tests/run.sh eingebunden (nicht einzeln ausführen).

# ---------------------------------------------------------------------------
t_group "gd_version_ge"
t_ok "1.12.2 >= 1.11.3"            gd_version_ge 1.12.2 1.11.3
t_no "1.11.3 >= 1.12.2 ist falsch" gd_version_ge 1.11.3 1.12.2
t_ok "gleiche Version"             gd_version_ge 1.15.1 1.15.1
t_ok "mehrstellig: 1.10.0 >= 1.9.9"  gd_version_ge 1.10.0 1.9.9
t_no "mehrstellig: 1.9.0 >= 1.10.0 ist falsch" gd_version_ge 1.9.0 1.10.0
t_ok "Major: 2.0.0 >= 1.99.9"      gd_version_ge 2.0.0 1.99.9
t_no "Major: 1.99.9 >= 2.0.0 ist falsch" gd_version_ge 1.99.9 2.0.0
t_ok "Grenze nginx: 1.25.1 >= 1.25.1" gd_version_ge 1.25.1 1.25.1
t_no "Grenze nginx: 1.25.0 >= 1.25.1 ist falsch" gd_version_ge 1.25.0 1.25.1
t_ok "zwei Stellen: 1.15 <= 1.15.1" gd_version_ge 1.15.1 1.15
t_no "zwei Stellen: 1.15 >= 1.15.1 ist falsch" gd_version_ge 1.15 1.15.1
t_ok "vier Stellen: 1.2.3.4 >= 1.2.3" gd_version_ge 1.2.3.4 1.2.3

# ---------------------------------------------------------------------------
t_group "gd_ip_to_int"
t_eq "0.0.0.0"           0           "$(gd_ip_to_int 0.0.0.0)"
t_eq "1.2.3.4"           16909060    "$(gd_ip_to_int 1.2.3.4)"
t_eq "255.255.255.255"   4294967295  "$(gd_ip_to_int 255.255.255.255)"
t_eq "10.1.0.1"          167837697   "$(gd_ip_to_int 10.1.0.1)"
t_eq "führende Nullen sind dezimal (010 = 10)" 167837697 "$(gd_ip_to_int 010.001.000.001)"
t_eq "08.8.8.8 (08 ist keine gültige Oktalzahl)" 134744072 "$(gd_ip_to_int 08.8.8.8)"
t_no "Oktett 256"        gd_ip_to_int 256.1.1.1
t_no "zu wenige Oktette" gd_ip_to_int 1.2.3
t_no "zu viele Oktette"  gd_ip_to_int 1.2.3.4.5
t_no "Buchstaben"        gd_ip_to_int a.b.c.d
t_no "leer"              gd_ip_to_int ""
t_no "vierstelliges Oktett" gd_ip_to_int 1.2.3.0004
t_no "IPv6"              gd_ip_to_int ::1

# ---------------------------------------------------------------------------
t_group "gd_ip_in_cidr"
t_ok "10.1.2.3 in 10.0.0.0/8"          gd_ip_in_cidr 10.1.2.3 10.0.0.0/8
t_no "11.0.0.1 nicht in 10.0.0.0/8"    gd_ip_in_cidr 11.0.0.1 10.0.0.0/8
t_ok "192.168.1.130 in 192.168.1.128/25" gd_ip_in_cidr 192.168.1.130 192.168.1.128/25
t_no "192.168.1.127 nicht in 192.168.1.128/25" gd_ip_in_cidr 192.168.1.127 192.168.1.128/25
t_ok "/32 trifft genau eine Adresse"   gd_ip_in_cidr 1.2.3.4 1.2.3.4/32
t_no "/32 trifft Nachbar nicht"        gd_ip_in_cidr 1.2.3.5 1.2.3.4/32
t_ok "/0 trifft alles"                 gd_ip_in_cidr 8.8.8.8 0.0.0.0/0
t_ok "Netzadresse mit Hostbits wird maskiert" gd_ip_in_cidr 10.9.9.9 10.1.1.1/8
t_ok "führende Nullen in Adresse und Netz" gd_ip_in_cidr 010.001.002.003 010.0.0.0/8
t_no "ungültige Adresse"               gd_ip_in_cidr 999.1.1.1 10.0.0.0/8
t_no "ungültiges Netz"                 gd_ip_in_cidr 10.1.1.1 abc/8
t_no "Länge über 32"                   gd_ip_in_cidr 10.1.1.1 10.0.0.0/33
t_no "Länge keine Zahl"                gd_ip_in_cidr 10.1.1.1 10.0.0.0/x
t_no "Netz ohne Länge"                 gd_ip_in_cidr 10.1.1.1 10.0.0.0

# ---------------------------------------------------------------------------
t_group "gd_is_cloudflare_ip"
t_ok "104.16.0.1 (104.16.0.0/13)"          gd_is_cloudflare_ip 104.16.0.1
t_ok "104.23.255.255 (Ende von /13)"       gd_is_cloudflare_ip 104.23.255.255
t_ok "173.245.48.1 (erstes Netz)"          gd_is_cloudflare_ip 173.245.48.1
t_no "173.245.64.1 (hinter /20)"           gd_is_cloudflare_ip 173.245.64.1
t_ok "172.64.0.1 (172.64.0.0/13)"          gd_is_cloudflare_ip 172.64.0.1
t_ok "172.71.255.255 (Ende von /13)"       gd_is_cloudflare_ip 172.71.255.255
t_no "172.72.0.0 (hinter /13)"             gd_is_cloudflare_ip 172.72.0.0
t_ok "162.159.255.255 (162.158.0.0/15)"    gd_is_cloudflare_ip 162.159.255.255
t_no "162.160.0.0 (hinter /15)"            gd_is_cloudflare_ip 162.160.0.0
t_ok "131.0.75.255 (131.0.72.0/22)"        gd_is_cloudflare_ip 131.0.75.255
t_no "131.0.76.0 (hinter /22)"             gd_is_cloudflare_ip 131.0.76.0
t_ok "197.234.240.1 (197.234.240.0/22)"    gd_is_cloudflare_ip 197.234.240.1
t_no "8.8.8.8 ist kein Proxy-Netz"         gd_is_cloudflare_ip 8.8.8.8
t_no "1.1.1.1 (DNS-Dienst, kein Proxy-Netz)" gd_is_cloudflare_ip 1.1.1.1
t_no "ungültige Adresse"                   gd_is_cloudflare_ip 999.1.1.1
t_no "Text statt Adresse"                  gd_is_cloudflare_ip abc
t_no "leer"                                gd_is_cloudflare_ip ""
t_ok "führende Nullen: 104.016.000.001"    gd_is_cloudflare_ip 104.016.000.001
_cf_bad=""
for _cf_net in "${GD_CLOUDFLARE_NETS[@]}"; do
    gd_is_cloudflare_ip "${_cf_net%/*}" || _cf_bad="$_cf_bad $_cf_net"
done
t_eq "jedes Netz aus GD_CLOUDFLARE_NETS trifft seine eigene Netzadresse" "" "$_cf_bad"
unset _cf_net _cf_bad

# ---------------------------------------------------------------------------
t_group "gd_is_private_ip"
t_ok "10.0.0.1"         gd_is_private_ip 10.0.0.1
t_ok "172.16.0.1"       gd_is_private_ip 172.16.0.1
t_ok "172.31.255.1"     gd_is_private_ip 172.31.255.1
t_no "172.32.0.1"       gd_is_private_ip 172.32.0.1
t_ok "192.168.178.20"   gd_is_private_ip 192.168.178.20
t_ok "100.64.0.1 (CGNAT)" gd_is_private_ip 100.64.0.1
t_ok "127.0.0.1"        gd_is_private_ip 127.0.0.1
t_ok "169.254.1.1"      gd_is_private_ip 169.254.1.1
t_no "8.8.8.8"          gd_is_private_ip 8.8.8.8
t_no "Text"             gd_is_private_ip abc

# ---------------------------------------------------------------------------
t_group "gd_valid_domain"
t_ok "panel.example.de"        gd_valid_domain panel.example.de
t_ok "example.com"             gd_valid_domain example.com
t_ok "a-b.c-d.example.online"  gd_valid_domain a-b.c-d.example.online
t_ok "lange TLD (.gratis)"     gd_valid_domain meine.seite.gratis
t_ok "Punycode-Label"          gd_valid_domain xn--mnchen-3ya.de
t_ok "Label mit 63 Zeichen"    gd_valid_domain "$(printf 'a%.0s' {1..63}).de"
t_no "Label mit 64 Zeichen"    gd_valid_domain "$(printf 'a%.0s' {1..64}).de"
t_no "länger als 253 Zeichen"  gd_valid_domain "$(printf 'abcdefghi.%.0s' {1..26})de"
t_no "ohne TLD (localhost)"    gd_valid_domain localhost
t_no "Bindestrich am Anfang"   gd_valid_domain -a.example.com
t_no "Bindestrich am Ende"     gd_valid_domain a-.example.com
t_no "doppelter Punkt"         gd_valid_domain a..example.com
t_no "Punkt am Ende"           gd_valid_domain example.com.
t_no "einstellige TLD"         gd_valid_domain example.c
t_no "numerische TLD"          gd_valid_domain example.123
t_no "IP-Adresse"              gd_valid_domain 1.2.3.4
t_no "Leerzeichen"             gd_valid_domain "exa mple.com"
t_no "Unterstrich"             gd_valid_domain exa_mple.com
t_no "mit Schema"              gd_valid_domain https://example.com
t_no "leer"                    gd_valid_domain ""

# ---------------------------------------------------------------------------
t_group "gd_valid_email"
t_ok "name@example.de"            gd_valid_email name@example.de
t_ok "Plus-Adresse"               gd_valid_email vor.name+tag@mail.example.de
t_ok "Unterstrich und Prozent"    gd_valid_email a_b%c@example.com
t_no "ohne @"                     gd_valid_email name.example.de
t_no "ohne Domain-Punkt"          gd_valid_email name@localhost
t_no "doppeltes @"                gd_valid_email a@@example.de
t_no "ohne lokalen Teil"          gd_valid_email @example.de
t_no "Leerzeichen"                gd_valid_email "a b@example.de"
t_no "Punkt am Ende der Domain"   gd_valid_email a@example.de.
t_no "numerische TLD"             gd_valid_email a@example.123
t_no "leer"                       gd_valid_email ""

# ---------------------------------------------------------------------------
t_group "gd_valid_port_range"
t_ok "25565-25600"                gd_valid_port_range 25565-25600
t_ok "genau 1000 Ports (1025-2024)" gd_valid_port_range 1025-2024
t_no "1001 Ports (1025-2025)"     gd_valid_port_range 1025-2025
t_ok "obere Grenze 64600-65535"   gd_valid_port_range 64600-65535
t_no "über 65535"                 gd_valid_port_range 65000-65536
t_no "Start 1024 ist zu klein"    gd_valid_port_range 1024-2000
t_no "Start nach Ende"            gd_valid_port_range 25600-25565
t_no "zu groß (40000 Ports)"      gd_valid_port_range 25565-65535
t_ok "ein einzelner Port als Bereich" gd_valid_port_range 25565-25565
t_no "dreistellig (80-90)"        gd_valid_port_range 80-90
t_no "ohne Bereich"               gd_valid_port_range 25565
t_no "offenes Ende"               gd_valid_port_range 25565-
t_no "Text"                       gd_valid_port_range abc-def
t_no "leer"                       gd_valid_port_range ""

# ---------------------------------------------------------------------------
t_group "gd_dotenv_set"
_env="$GD_TMP/test.env"
printf 'APP_URL=https://alt.example.de\nAPP_ENV=production\n' > "$_env"
chmod 600 "$_env"
t_ok "vorhandenen Schlüssel ersetzen" gd_dotenv_set "$_env" APP_URL "https://neu.example.de"
t_eq "Wert ersetzt, Rest unverändert" $'APP_URL=https://neu.example.de\nAPP_ENV=production' "$(cat "$_env")"
t_eq "Rechte sind 640" 640 "$(stat -c %a "$_env")"

t_ok "neuen Schlüssel anhängen" gd_dotenv_set "$_env" DB_HOST 127.0.0.1
t_eq "neuer Schlüssel steht am Ende" $'APP_URL=https://neu.example.de\nAPP_ENV=production\nDB_HOST=127.0.0.1' "$(cat "$_env")"

_special='pa|ss&wo\rd\1$x"q'"'"'#=;'
t_ok "Sonderzeichen | & \\ im Wert (ersetzen)" gd_dotenv_set "$_env" APP_ENV "$_special"
t_eq "Sonderzeichen unverändert (ersetzt)" "APP_ENV=$_special" "$(grep '^APP_ENV=' "$_env")"
t_ok "Sonderzeichen | & \\ im Wert (neu)" gd_dotenv_set "$_env" DB_PASSWORD "$_special"
t_eq "Sonderzeichen unverändert (neu)" "DB_PASSWORD=$_special" "$(grep '^DB_PASSWORD=' "$_env")"
t_eq "andere Zeilen blieben unberührt" 4 "$(grep -c . "$_env")"

printf 'A=1\nB=2' > "$_env"
t_ok "Datei ohne Zeilenende: neuen Schlüssel anhängen" gd_dotenv_set "$_env" C 3
t_eq "letzte Zeile wurde nicht verklebt" $'A=1\nB=2\nC=3' "$(cat "$_env")"

printf 'A=1\nB=2' > "$_env"
t_ok "Datei ohne Zeilenende: letzten Schlüssel ersetzen" gd_dotenv_set "$_env" B 9
t_eq "ersetzt, jetzt mit Zeilenende" $'A=1\nB=9' "$(cat "$_env")"

printf 'APP_URL_EXTRA=1\nAPP=2\n' > "$_env"
gd_dotenv_set "$_env" APP_URL x
t_eq "Schlüssel mit gleichem Anfang wird nicht überschrieben" $'APP_URL_EXTRA=1\nAPP=2\nAPP_URL=x' "$(cat "$_env")"

printf 'A=1\n' > "$_env"
t_no "Zeilenumbruch im Wert wird abgelehnt" gd_dotenv_set "$_env" A $'x\nEVIL=1'
t_eq "Datei blieb bei Ablehnung unverändert" "A=1" "$(cat "$_env")"
t_no "fehlende Datei wird abgelehnt" gd_dotenv_set "$GD_TMP/gibt-es-nicht.env" A 1
t_ok "leerer Wert ist erlaubt" gd_dotenv_set "$_env" A ""
t_eq "leerer Wert wird geschrieben" "A=" "$(cat "$_env")"

: > "$_env"
t_ok "leere Datei: Schlüssel anhängen" gd_dotenv_set "$_env" A 1
t_eq "leere Datei ergibt genau eine Zeile" "A=1" "$(cat "$_env")"
t_eq "keine Reste im Temp-Verzeichnis" 0 "$(find "$GD_TMP" -maxdepth 1 -name 'dotenv.*' | wc -l)"
unset _env _special

# ---------------------------------------------------------------------------
t_group "gd_conf_set / gd_conf_get"
t_eq "ungesetzter Schlüssel ist leer (ohne Datei)" "" "$(gd_conf_get PANEL_DOMAIN)"
gd_conf_set PANEL_DOMAIN panel.example.de
t_eq "Wert wird gelesen" panel.example.de "$(gd_conf_get PANEL_DOMAIN)"
gd_conf_set PANEL_DOMAIN neu.example.de
t_eq "Überschreiben ersetzt den Wert" neu.example.de "$(gd_conf_get PANEL_DOMAIN)"
t_eq "es gibt nur eine Zeile je Schlüssel" 1 "$(grep -c '^PANEL_DOMAIN=' "$GD_CONF_FILE")"
gd_conf_set SONDER 'a b|c&d$e"f'"'"'g'
t_eq "Sonderzeichen überstehen den Weg (%q)" 'a b|c&d$e"f'"'"'g' "$(gd_conf_get SONDER)"
t_eq "anderer Schlüssel blieb erhalten" neu.example.de "$(gd_conf_get PANEL_DOMAIN)"
t_eq "Konfigurationsdatei hat Rechte 600" 600 "$(stat -c %a "$GD_CONF_FILE")"
t_eq "Konfigurationsverzeichnis hat Rechte 700" 700 "$(stat -c %a "$GD_CONF_DIR")"
t_eq "ungesetzter Schlüssel ist leer" "" "$(gd_conf_get GIBT_ES_NICHT)"

# ---------------------------------------------------------------------------
t_group "gd_gen_password"
t_eq "Standardlänge 32" 32 "$(gd_gen_password | tr -d '\n' | wc -c)"
t_eq "Länge 8"  8  "$(gd_gen_password 8  | tr -d '\n' | wc -c)"
t_eq "Länge 64" 64 "$(gd_gen_password 64 | tr -d '\n' | wc -c)"
_pw_bad=0
for _i in $(seq 1 30); do
    _pw="$(gd_gen_password 12)"
    [[ "$_pw" =~ ^[A-Za-z0-9]{12}$ ]] || _pw_bad=$((_pw_bad + 1))
    [[ "$_pw" =~ [A-Z] && "$_pw" =~ [a-z] && "$_pw" =~ [0-9] ]] || _pw_bad=$((_pw_bad + 1))
done
t_eq "30 Passwörter: nur Buchstaben/Zahlen, je Klasse mindestens ein Zeichen" 0 "$_pw_bad"
t_no "zwei Aufrufe liefern verschiedene Passwörter" test "$(gd_gen_password)" = "$(gd_gen_password)"
unset _pw _pw_bad _i
