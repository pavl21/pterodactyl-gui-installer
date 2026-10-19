#!/bin/bash
# Pfad: tests/test_analyse.sh
# Tests für die Parser in analyse.sh: yaml_get, rc_get, rc_webroots, le_name_from_path, valid_cert_name,
# renew_threshold_days, certbot_log_status.
# analyse.sh lässt sich nicht per "source" laden: Die Datei verlangt gleich am Anfang root (gd_require_root) und führt
# danach sofort die Analyse aus. Die Funktionen werden deshalb per t_fn aus dem Skript herausgeschnitten und in der
# Test-Shell definiert. Ändert sich der Aufbau von analyse.sh so, dass eine Funktion nicht mehr gefunden wird, schlägt
# der Test mit "Funktion ... gefunden" fehl.
# Wird von tests/run.sh eingebunden (nicht einzeln ausführen).

t_group "analyse.sh: Funktionen herauslösen"
for _fn in yaml_get rc_get rc_webroots le_name_from_path valid_cert_name renew_threshold_days certbot_log_status; do
    t_fn analyse.sh "$_fn" && t_ok "Funktion $_fn geladen" declare -F "$_fn"
done
unset _fn

# Verzeichnisse von certbot liegen in der Sandbox (analyse.sh liest GD_LE_DIR / GD_LE_LOG_DIR genauso)
LE_DIR="$GD_TMP/letsencrypt"
LE_LOG_DIR="$GD_TMP/letsencrypt-log"
mkdir -p "$LE_DIR/renewal" "$LE_LOG_DIR"

# ---------------------------------------------------------------------------
t_group "yaml_get"
_yml="$GD_TMP/config.yml"
cat > "$_yml" <<'YML'
# Wings-Konfiguration
debug: false
uuid: 11111111-2222-3333-4444-555555555555
api:
  host: 0.0.0.0
  port: 443
  ssl:
    enabled: true
    cert: /etc/letsencrypt/live/node.example.de/fullchain.pem   # Kommentar am Zeilenende
    key: '/etc/letsencrypt/live/node.example.de/privkey.pem'
  upload_limit: 100
system:
  data: "/var/lib/pterodactyl/volumes"
  sftp:
    bind_port: 2022
allowed_origins:
  - https://panel.example.de
remote: 'https://panel.example.de'
YML
t_eq "oberste Ebene"                         false          "$(yaml_get "$_yml" debug)"
t_eq "zweite Ebene"                          443            "$(yaml_get "$_yml" api.port)"
t_eq "dritte Ebene (api.ssl.cert), Kommentar entfernt" /etc/letsencrypt/live/node.example.de/fullchain.pem "$(yaml_get "$_yml" api.ssl.cert)"
t_eq "einfache Anführungszeichen werden entfernt" /etc/letsencrypt/live/node.example.de/privkey.pem "$(yaml_get "$_yml" api.ssl.key)"
t_eq "doppelte Anführungszeichen werden entfernt" /var/lib/pterodactyl/volumes "$(yaml_get "$_yml" system.data)"
t_eq "zurück auf die höhere Ebene (api.upload_limit)" 100  "$(yaml_get "$_yml" api.upload_limit)"
t_eq "andere Verschachtelung (system.sftp.bind_port)" 2022 "$(yaml_get "$_yml" system.sftp.bind_port)"
t_eq "Wert mit Doppelpunkt (remote)"         https://panel.example.de "$(yaml_get "$_yml" remote)"
t_eq "Schlüssel ohne Wert (api.ssl)"         ""             "$(yaml_get "$_yml" api.ssl)"
t_eq "falsche Ebene (port statt api.port)"   ""             "$(yaml_get "$_yml" port)"
t_eq "unbekannter Pfad"                      ""             "$(yaml_get "$_yml" api.ssl.gibt_es_nicht)"
t_eq "Listeneinträge werden ignoriert"       ""             "$(yaml_get "$_yml" allowed_origins)"
t_eq "fehlende Datei"                        ""             "$(yaml_get "$GD_TMP/gibt-es-nicht.yml" api.port)"
unset _yml

# ---------------------------------------------------------------------------
t_group "rc_get / rc_webroots (Erneuerungskonfiguration von certbot)"
cat > "$LE_DIR/renewal/panel.example.de.conf" <<'CONF'
# renew_before_expiry = 30 days
version = 2.9.0
archive_dir = /etc/letsencrypt/archive/panel.example.de
cert = /etc/letsencrypt/live/panel.example.de/cert.pem

# Options used in the renewal process
[renewalparams]
account = 0123456789abcdef
authenticator = webroot
webroot_path = /var/www/pterodactyl/public, /var/www/html,
server = https://acme-v02.api.letsencrypt.org/directory
key_type = ecdsa
[[webroot_map]]
panel.example.de = /var/www/pterodactyl/public
www.panel.example.de = /var/www/html
CONF
t_eq "Wert im Kopf (version)"                2.9.0          "$(rc_get panel.example.de version)"
t_eq "Wert in [renewalparams] (authenticator)" webroot      "$(rc_get panel.example.de authenticator)"
t_eq "Wert mit Gleichheitszeichen im Inhalt" https://acme-v02.api.letsencrypt.org/directory "$(rc_get panel.example.de server)"
t_eq "auskommentierte Zeile zählt nicht (renew_before_expiry)" "" "$(rc_get panel.example.de renew_before_expiry)"
t_eq "Einträge in [[webroot_map]] zählen nicht (domain)" "" "$(rc_get panel.example.de www.panel.example.de)"
t_eq "unbekannter Schlüssel"                 ""             "$(rc_get panel.example.de gibt_es_nicht)"
t_eq "unbekanntes Zertifikat"                ""             "$(rc_get gibt-es-nicht.example.de authenticator)"
t_eq "Webroots: webroot_path und webroot_map, sortiert und ohne Doppelte" $'/var/www/html\n/var/www/pterodactyl/public' "$(rc_webroots panel.example.de)"
t_eq "Webroots: unbekanntes Zertifikat"      ""             "$(rc_webroots gibt-es-nicht.example.de)"

printf '%s\n' '# renew_before_expiry = 30 days' 'renew_before_expiry = 40 days' '[renewalparams]' 'authenticator = standalone' > "$LE_DIR/renewal/standalone.example.de.conf"
t_eq "eigene Einstellung im Kopf (renew_before_expiry)" "40 days" "$(rc_get standalone.example.de renew_before_expiry)"
t_eq "Webroots bei standalone: keine"        ""             "$(rc_webroots standalone.example.de)"

# ---------------------------------------------------------------------------
t_group "renew_threshold_days (mit renew_before_expiry, ohne openssl)"
printf '%s\n' 'renew_before_expiry = 30 days' '[renewalparams]' 'authenticator = webroot' > "$LE_DIR/renewal/t30.conf"
printf '%s\n' 'renew_before_expiry = 10 days' '[renewalparams]' > "$LE_DIR/renewal/t10.conf"
printf '%s\n' 'renew_before_expiry = 1 day'   '[renewalparams]' > "$LE_DIR/renewal/t1.conf"
printf '%s\n' 'renew_before_expiry = 3 days'  '[renewalparams]' > "$LE_DIR/renewal/t3.conf"
t_eq "30 Tage -> 25 (5 Tage Puffer)"          25  "$(renew_threshold_days /nicht/vorhanden t30)"
t_eq "10 Tage -> 5"                           5   "$(renew_threshold_days /nicht/vorhanden t10)"
t_eq "1 Tag -> mindestens 1"                  1   "$(renew_threshold_days /nicht/vorhanden t1)"
t_eq "3 Tage -> mindestens 1"                 1   "$(renew_threshold_days /nicht/vorhanden t3)"

# ---------------------------------------------------------------------------
t_group "le_name_from_path / valid_cert_name"
t_eq "Pfad unterhalb von live/"               panel.example.de "$(le_name_from_path "$LE_DIR/live/panel.example.de/fullchain.pem")"
t_eq "Zertifikat außerhalb von certbot"       ""  "$(le_name_from_path /etc/ssl/certs/eigenes.pem)"
t_eq "Pfad direkt in live/ ohne Unterordner"  ""  "$(le_name_from_path "$LE_DIR/live/fullchain.pem")"
t_ok "Name panel.example.de"                  valid_cert_name panel.example.de
t_ok "Name mit Bindestrich und Zahl"          valid_cert_name node-1.example.de
t_ok "Name mit Suffix (certbot: -0001)"       valid_cert_name panel.example.de-0001
t_no "Name mit Semikolon (Befehlsinjektion)"  valid_cert_name 'a;rm -rf /'
t_no "Name mit \$()"                          valid_cert_name 'a$(id)'
t_no "Name mit Leerzeichen"                   valid_cert_name 'a b'
t_no "Name beginnt mit Punkt"                 valid_cert_name .hidden
t_no "Name beginnt mit Bindestrich"           valid_cert_name -x
t_no "leerer Name"                            valid_cert_name ""

# ---------------------------------------------------------------------------
t_group "certbot_log_status"
t_eq "ohne Logdateien: keine Ausgabe" "" "$(certbot_log_status)"
cat > "$LE_LOG_DIR/letsencrypt.log.1" <<'LOG'
2026-10-01 03:00:01,123:DEBUG:certbot._internal.main:certbot version: 2.9.0
2026-10-01 03:00:02,000:INFO:certbot._internal.renewal:Processing /etc/letsencrypt/renewal/panel.example.de.conf
2026-10-01 03:00:02,100:INFO:certbot._internal.renewal:Certificate not yet due for renewal
2026-10-01 03:00:03,000:INFO:certbot._internal.renewal:Processing /etc/letsencrypt/renewal/node.example.de.conf
2026-10-01 03:00:03,500:DEBUG:acme.client:Could not bind to IPv4 or IPv6.
2026-10-01 03:00:04,000:WARNING:certbot._internal.renewal:Attempting to renew cert (node.example.de) from /etc/letsencrypt/renewal/node.example.de.conf produced an unexpected error: Problem binding to port 80: Could not bind to IPv4 or IPv6.. Skipping.
LOG
_out="$(certbot_log_status)"
t_eq "erste Zeile: Zeitpunkt des letzten Laufs" $'R\t2026-10-01 03:00:03' "$(sed -n 1p <<< "$_out")"
t_eq "Zertifikat ohne Fälligkeit: ok/due" $'C\tpanel.example.de\tok\t2026-10-01 03:00:02\tdue\t-' "$(sed -n 2p <<< "$_out")"
t_eq "gescheiterte Erneuerung: fail mit Ursache" $'C\tnode.example.de\tfail\t2026-10-01 03:00:04\t-\tCould not bind to IPv4 or IPv6.' "$(sed -n 3p <<< "$_out")"
t_eq "genau drei Zeilen" 3 "$(wc -l <<< "$_out")"

# Neueres Log (letsencrypt.log): node.example.de wird jetzt erfolgreich erneuert – es gilt der neueste Stand
cat > "$LE_LOG_DIR/letsencrypt.log" <<'LOG'
2026-10-02 03:00:01,000:DEBUG:certbot._internal.main:certbot version: 2.9.0
2026-10-02 03:00:02,000:INFO:certbot._internal.renewal:Processing /etc/letsencrypt/renewal/node.example.de.conf
2026-10-02 03:00:09,000:INFO:certbot._internal.renewal:Congratulations! Your certificate and chain have been saved at:
2026-10-02 03:00:09,500:INFO:certbot._internal.renewal:all renewals succeeded
LOG
_out="$(certbot_log_status)"
t_eq "neuester Lauf bestimmt den Zeitpunkt" $'R\t2026-10-02 03:00:02' "$(sed -n 1p <<< "$_out")"
t_eq "unverändertes Zertifikat bleibt (Reihenfolge: zuerst gesehen)" $'C\tpanel.example.de\tok\t2026-10-01 03:00:02\tdue\t-' "$(sed -n 2p <<< "$_out")"
t_eq "später erfolgreiche Erneuerung ersetzt den Fehler" $'C\tnode.example.de\tok\t2026-10-02 03:00:09\trenewed\t-' "$(sed -n 3p <<< "$_out")"
t_eq "weiterhin drei Zeilen" 3 "$(wc -l <<< "$_out")"
unset _out
