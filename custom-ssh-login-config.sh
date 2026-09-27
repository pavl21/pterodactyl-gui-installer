#!/bin/bash
# Pfad: custom-ssh-login-config.sh
# Eigene Login-Anzeige (MOTD) für SSH einrichten oder entfernen.

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

MOTD_BIN="/usr/local/bin/germandactyl-motd"
MOTD_HOOK="/etc/profile.d/germandactyl-motd.sh"

remove_old_version() {
    # Frühere Versionen lagen unter /etc/motd.sh (mit unsicheren Rechten 777) und wurden aus /etc/profile gestartet
    rm -f /etc/motd.sh
    sed -i '\#^/etc/motd.sh$#d' /etc/profile
}

if [ -f "$MOTD_BIN" ] || [ -f /etc/motd.sh ]; then
    if gd_yesno "🛑 SSH-Loginseite bereits aktiv" "Die GermanDactyl-Loginseite ist bereits eingerichtet. Möchtest du sie entfernen? Danach wird wieder die Standardanzeige deines Systems verwendet." 11 74; then
        rm -f "$MOTD_BIN" "$MOTD_HOOK"
        remove_old_version
        gd_msg "✅ SSH-Loginseite entfernt" "Die Standardanzeige deines Systems wird wieder verwendet." 8 70
    elif [ -f /etc/motd.sh ]; then
        # Alte, unsichere Installation automatisch auf die neue Variante umstellen
        remove_old_version
        gd_fetch motd.sh "$GD_TMP/motd.sh" && install -o root -g root -m 755 "$GD_TMP/motd.sh" "$MOTD_BIN"
        printf '%s\n' '# Angelegt von GermanDactyl Setup: Loginseite nur in interaktiven Shells anzeigen' \
            'case $- in *i*) [ -x /usr/local/bin/germandactyl-motd ] && /usr/local/bin/germandactyl-motd ;; esac' > "$MOTD_HOOK"
        chmod 644 "$MOTD_HOOK"
        gd_msg "🔒 Sicherheitsupdate" "Deine Loginseite wurde auf die neue, sichere Variante umgestellt (vorher war die Datei für alle Benutzer beschreibbar)." 10 74
    fi
    exit 0
fi

if ! gd_yesno "🐾 GermanDactyl SSH-Login" "Wenn du diesen Server nur für Pterodactyl verwendest, ist diese Loginseite für dich eventuell praktisch: Nach dem Anmelden per SSH siehst du den aktuellen Zustand des Servers (Updates, Laufzeit, Netzwerk, letzter Login).\n\nDu kannst sie jederzeit über denselben Menüpunkt wieder entfernen.\n\nMöchtest du fortfahren?" 15 78; then
    exit 0
fi

clear
echo "Benötigte Pakete werden installiert..."
gd_apt_install lolcat figlet vnstat jq bc >> "$GD_LOG" 2>&1
systemctl enable --now vnstat >> "$GD_LOG" 2>&1

if ! gd_fetch motd.sh "$GD_TMP/motd.sh"; then
    gd_msg "Fehler" "Die Loginseite konnte nicht heruntergeladen werden." 8 60
    exit 1
fi
install -o root -g root -m 755 "$GD_TMP/motd.sh" "$MOTD_BIN"
printf '%s\n' '# Angelegt von GermanDactyl Setup: Loginseite nur in interaktiven Shells anzeigen' \
    'case $- in *i*) [ -x /usr/local/bin/germandactyl-motd ] && /usr/local/bin/germandactyl-motd ;; esac' > "$MOTD_HOOK"
chmod 644 "$MOTD_HOOK"

gd_msg "🎉 SSH-Loginseite aktiviert" "Die Loginseite wurde eingerichtet und erscheint ab der nächsten SSH-Anmeldung. Wenn sie dir nicht gefällt, kannst du sie über denselben Menüpunkt wieder entfernen." 11 74
"$MOTD_BIN"
echo ""
read -r -p "Drücke Enter, um zum Menü zurückzukehren..." _ < /dev/tty
