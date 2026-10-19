#!/bin/bash
# Pfad: tests/test_panel.sh
# Tests für lib/panel.sh: nginx-Version und http2-Direktive (gestubbtes nginx), Umstellung der certbot-Erneuerung.
# Wird von tests/run.sh eingebunden (nicht einzeln ausführen).

# ---------------------------------------------------------------------------
t_group "gd_nginx_http2_directive (nginx als Stub im PATH)"
_nginx_stub() {
    # _nginx_stub <ausgabe> – legt ein nginx-Programm an, das wie "nginx -v" auf stderr antwortet
    printf '#!/bin/sh\necho "%s" >&2\n' "$1" > "$SANDBOX/bin/nginx"
    chmod +x "$SANDBOX/bin/nginx"
}
_nginx_stub "nginx version: nginx/1.22.1"
t_eq "gd_nginx_version liest 1.22.1" 1.22.1 "$(gd_nginx_version)"
t_no "nginx 1.22.1 -> alte Form (listen ... http2)" gd_nginx_http2_directive
_nginx_stub "nginx version: nginx/1.24.0 (Ubuntu)"
t_no "nginx 1.24.0 -> alte Form" gd_nginx_http2_directive
_nginx_stub "nginx version: nginx/1.25.0"
t_no "nginx 1.25.0 -> alte Form" gd_nginx_http2_directive
_nginx_stub "nginx version: nginx/1.25.1"
t_ok "nginx 1.25.1 -> http2 on" gd_nginx_http2_directive
_nginx_stub "nginx version: nginx/1.26.3"
t_ok "nginx 1.26.3 -> http2 on" gd_nginx_http2_directive
_nginx_stub "nginx version: nginx/1.9.15"
t_no "nginx 1.9.15 -> alte Form (kein String-Vergleich)" gd_nginx_http2_directive
_nginx_stub "nginx version: nginx/1.100.0"
t_ok "nginx 1.100.0 -> http2 on (kein String-Vergleich)" gd_nginx_http2_directive
_nginx_stub "kaputte Ausgabe ohne Version"
t_eq "unbekannte Version: gd_nginx_version ist leer" "" "$(gd_nginx_version)"
t_no "unbekannte Version -> alte Form (läuft überall)" gd_nginx_http2_directive
rm -f "$SANDBOX/bin/nginx"
unset -f _nginx_stub

# ---------------------------------------------------------------------------
t_group "gd_certbot_conf_rewrite"
# Die Funktion liest /etc/letsencrypt/live/<domain>/cert.pem (nur lesend). Mit einer Domain, die es dort nicht
# gibt, fehlt die Datei, openssl liefert nichts und es gilt names=<domain> – ohne Zugriff auf das echte System.
_dom="gd-test.invalid"
_conf="$GD_TMP/renewal.conf"
_conf_new() {
    # _conf_new <authenticator> – typische Erneuerungskonfiguration von certbot
    cat > "$_conf" <<CONF
# renew_before_expiry = 30 days
version = 2.9.0
archive_dir = /etc/letsencrypt/archive/${_dom}
cert = /etc/letsencrypt/live/${_dom}/cert.pem
privkey = /etc/letsencrypt/live/${_dom}/privkey.pem
chain = /etc/letsencrypt/live/${_dom}/chain.pem
fullchain = /etc/letsencrypt/live/${_dom}/fullchain.pem

# Options used in the renewal process
[renewalparams]
account = 0123456789abcdef
pref_challs = http-01,
authenticator = $1
server = https://acme-v02.api.letsencrypt.org/directory
key_type = ecdsa
CONF
}
_conf_get() { awk -F' *= *' -v k="$1" '$1==k {print $2}' "$_conf"; }

_conf_new standalone
t_ok "standalone -> webroot" gd_certbot_conf_rewrite "$_conf" "$_dom" webroot /var/www/pterodactyl/public
t_eq "authenticator = webroot" webroot "$(_conf_get authenticator)"
t_eq "webroot_path gesetzt (mit Komma wie bei certbot)" "/var/www/pterodactyl/public," "$(_conf_get webroot_path)"
t_eq "pref_challs entfernt" 0 "$(grep -c '^pref_challs' "$_conf")"
t_eq "webroot_map-Abschnitt vorhanden" 1 "$(grep -c '^\[\[webroot_map\]\]' "$_conf")"
t_eq "webroot_map enthält die Domain" 1 "$(grep -cx "${_dom} = /var/www/pterodactyl/public" "$_conf")"
t_eq "andere Einträge bleiben erhalten (key_type)" ecdsa "$(_conf_get key_type)"
t_eq "andere Einträge bleiben erhalten (account)" 0123456789abcdef "$(_conf_get account)"
t_eq "Kopf bleibt erhalten (fullchain)" "/etc/letsencrypt/live/${_dom}/fullchain.pem" "$(_conf_get fullchain)"
t_eq "genau ein authenticator" 1 "$(grep -c '^authenticator' "$_conf")"
cp "$_conf" "$GD_TMP/renewal.once"
t_ok "webroot ein zweites Mal (idempotent)" gd_certbot_conf_rewrite "$_conf" "$_dom" webroot /var/www/pterodactyl/public
t_ok "Ergebnis ist nach dem zweiten Lauf unverändert" cmp -s "$_conf" "$GD_TMP/renewal.once"

t_ok "webroot -> dns-cloudflare" gd_certbot_conf_rewrite "$_conf" "$_dom" dns-cloudflare /etc/letsencrypt/cloudflare.ini
t_eq "authenticator = dns-cloudflare" dns-cloudflare "$(_conf_get authenticator)"
t_eq "Zugangsdaten-Datei gesetzt" /etc/letsencrypt/cloudflare.ini "$(_conf_get dns_cloudflare_credentials)"
t_eq "Wartezeit gesetzt" 30 "$(_conf_get dns_cloudflare_propagation_seconds)"
t_eq "webroot_path entfernt" 0 "$(grep -c '^webroot_path' "$_conf")"
t_eq "webroot_map entfernt (Abschnitt und Eintrag)" 0 "$(grep -c -e 'webroot_map' -e "^${_dom} =" "$_conf")"
t_eq "key_type nach dem Abschnitt bleibt erhalten" ecdsa "$(_conf_get key_type)"
cp "$_conf" "$GD_TMP/renewal.once"
t_ok "dns-cloudflare ein zweites Mal (idempotent)" gd_certbot_conf_rewrite "$_conf" "$_dom" dns-cloudflare /etc/letsencrypt/cloudflare.ini
t_ok "Ergebnis ist nach dem zweiten Lauf unverändert (DNS)" cmp -s "$_conf" "$GD_TMP/renewal.once"

t_ok "dns-cloudflare -> webroot" gd_certbot_conf_rewrite "$_conf" "$_dom" webroot /var/www/html
t_eq "zurück auf webroot" webroot "$(_conf_get authenticator)"
t_eq "DNS-Einträge entfernt" 0 "$(grep -c '^dns_cloudflare' "$_conf")"
t_eq "neuer Webroot in webroot_map" 1 "$(grep -cx "${_dom} = /var/www/html" "$_conf")"

_conf_new standalone
t_ok "Sonderzeichen im Pfad (| & \\)" gd_certbot_conf_rewrite "$_conf" "$_dom" webroot '/var/www/a|b&c\d'
t_eq "Pfad wird unverändert geschrieben (webroot_path)" '/var/www/a|b&c\d,' "$(_conf_get webroot_path)"
t_eq "Pfad wird unverändert geschrieben (webroot_map)" 1 "$(grep -cxF "${_dom} = /var/www/a|b&c\\d" "$_conf")"

# webroot_map als letzter Abschnitt mit Wildcard-ähnlichem Namen und Inhalt danach
printf '%s\n' '# kommentar' 'cert = /x' '[renewalparams]' 'authenticator = webroot' 'webroot_path = /alt,' 'key_type = rsa' \
    '[[webroot_map]]' "${_dom} = /alt" > "$_conf"
t_ok "webroot_map am Dateiende wird ersetzt" gd_certbot_conf_rewrite "$_conf" "$_dom" webroot /neu
t_eq "alter Webroot ist weg" 0 "$(grep -c '/alt' "$_conf")"
t_eq "neuer Webroot steht in der Map" 1 "$(grep -cx "${_dom} = /neu" "$_conf")"

printf 'cert = /x\n[renewalparams]\naccount = abc' > "$_conf"
t_no "ohne authenticator: Fehler" gd_certbot_conf_rewrite "$_conf" "$_dom" webroot /x
t_eq "ohne authenticator: Datei unverändert" $'cert = /x\n[renewalparams]\naccount = abc' "$(cat "$_conf")"
_conf_new standalone
cp "$_conf" "$GD_TMP/renewal.once"
t_no "unbekanntes Verfahren: Fehler" gd_certbot_conf_rewrite "$_conf" "$_dom" nginx /x
t_ok "unbekanntes Verfahren: Datei unverändert" cmp -s "$_conf" "$GD_TMP/renewal.once"
t_no "fehlende Datei: Fehler" gd_certbot_conf_rewrite "$GD_TMP/gibt-es-nicht.conf" "$_dom" webroot /x
unset -f _conf_new _conf_get
unset _dom _conf
