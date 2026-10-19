#!/bin/bash
# Pfad: scripts/sign-release.sh
# Erzeugt und prüft die signierte Prüfsummenliste (SHA256SUMS + SHA256SUMS.sig) für alle Skripte des Projekts.
# GermanDactyl Setup prüft damit jede nachgeladene Datei (installer.sh, lib/*.sh und alle Unterskripte).
# Läuft im Repository (auch aus einem anderen Verzeichnis aufrufbar), benötigt git, sha256sum und ssh-keygen.

set -u

NAMESPACE="germandactyl-setup"
DEFAULT_KEY="$HOME/.ssh/germandactyl-setup-signing"

usage() {
    cat <<EOF
Verwendung:
  scripts/sign-release.sh --sign [-k <privater-schlüssel>]   SHA256SUMS erzeugen und signieren
  scripts/sign-release.sh --check                            SHA256SUMS und Signatur prüfen (auch in der CI)
  scripts/sign-release.sh -h | --help                        diese Hilfe

Signiert werden alle Skripte, die git kennt: installer.sh, *.sh im Wurzelverzeichnis und lib/*.sh
(ohne scripts/). Neue Dateien vorher mit "git add" vormerken, sonst fehlen sie in der Liste.

Schlüssel: -k <datei>, sonst die Umgebungsvariable GERMANDACTYL_SETUP_SIGNING_KEY,
sonst $DEFAULT_KEY.

Schritte für den Projektinhaber (einmalig):
  1. Schlüssel erzeugen (am besten mit Passphrase, privaten Schlüssel nie ins Repository legen):
       ssh-keygen -t ed25519 -f ~/.ssh/germandactyl-setup-signing -C germandactyl-setup
  2. Inhalt von ~/.ssh/germandactyl-setup-signing.pub (eine Zeile: "ssh-ed25519 AAAA... germandactyl-setup")
     als Wert von GD_SIGNING_PUBKEY eintragen, in installer.sh UND in lib/common.sh (derselbe Wert).
  3. scripts/sign-release.sh --sign
  4. SHA256SUMS und SHA256SUMS.sig zusammen mit den Änderungen committen und pushen.

Vor JEDEM Push auf main (jede Änderung an einem Skript ändert die Prüfsumme):
  scripts/sign-release.sh --sign     (danach SHA256SUMS und SHA256SUMS.sig mit committen)
  scripts/sign-release.sh --check    (optional; prüft dasselbe wie die GitHub-Action)

Test-Branches (alles außer main) werden nicht signiert und ohne Prüfung geladen.
Solange GD_SIGNING_PUBKEY leer ist, prüft --check nur die Prüfsummen und die Signaturprüfung ist nicht aktiv.
EOF
}

die() { echo "Fehler: $*" >&2; exit 1; }

cd "$(dirname "${BASH_SOURCE[0]}")/.." || die "Repository-Verzeichnis nicht gefunden."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Kein git-Repository."
for tool in sha256sum ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool wurde nicht gefunden (ssh-keygen: Paket openssh-client)."
done

SUMS="SHA256SUMS"
SIG="SHA256SUMS.sig"
WORK="$(mktemp -d)" || die "Temporäres Verzeichnis konnte nicht angelegt werden."
trap 'rm -rf "$WORK"' EXIT

script_files() {
    # Alle zu signierenden Skripte, sortiert (nur vorhandene Dateien)
    local f
    git ls-files 'installer.sh' '*.sh' 'lib/*.sh' \
        | grep -E '^(installer\.sh|[^/]+\.sh|lib/[^/]+\.sh)$' \
        | LC_ALL=C sort -u \
        | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done
}

make_sums() {
    # make_sums <ausgabedatei> – Zeilen im Format von sha256sum ("<hash>  <pfad>")
    local list
    list="$(script_files)"
    [ -n "$list" ] || die "Keine Skripte gefunden."
    : > "$1"
    while IFS= read -r f; do
        sha256sum -- "$f" >> "$1"
    done <<< "$list"
}

pubkey_of() {
    # pubkey_of <datei> – Wert von GD_SIGNING_PUBKEY (leer, falls nicht gesetzt)
    sed -n 's/^GD_SIGNING_PUBKEY="\(.*\)"[[:space:]]*$/\1/p' "$1" | head -n1
}

verify_sig() {
    # verify_sig <pubkey> <sums-datei> <sig-datei> – prüft wie installer.sh (allowed_signers-Format)
    local allowed="$WORK/allowed_signers"
    ( umask 077; printf '%s %s\n' "$NAMESPACE" "$1" > "$allowed" )
    ssh-keygen -Y verify -f "$allowed" -I "$NAMESPACE" -n "$NAMESPACE" -s "$3" < "$2" >/dev/null 2>&1
}

key_core() {
    # Schlüsseltyp + Base64-Teil (ohne Kommentar), zum Vergleich zweier Public Keys
    awk '{ print $1, $2 }' <<< "$1"
}

valid_pubkey_format() {
    [[ "$1" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?$ ]]
}

do_sign() {
    local key="$1" pub_installer pub_common pub_file
    [ -f "$key" ] || die "Privater Schlüssel nicht gefunden: $key (siehe: scripts/sign-release.sh --help)"

    pub_installer="$(pubkey_of installer.sh)"
    pub_common="$(pubkey_of lib/common.sh)"
    if [ "$pub_installer" != "$pub_common" ]; then
        die "GD_SIGNING_PUBKEY ist in installer.sh und lib/common.sh unterschiedlich. Beide Stellen müssen denselben Wert tragen."
    fi
    if [ -n "$pub_installer" ]; then
        valid_pubkey_format "$pub_installer" || die "GD_SIGNING_PUBKEY hat kein gültiges Format (erwartet: \"ssh-ed25519 AAAA... germandactyl-setup\")."
        if [ -f "$key.pub" ]; then
            pub_file="$(cat "$key.pub")"
            [ "$(key_core "$pub_file")" = "$(key_core "$pub_installer")" ] \
                || die "Der Public Key in installer.sh/lib/common.sh gehört nicht zum Schlüssel $key. Clients würden die Signatur ablehnen."
        fi
    else
        echo "Hinweis: GD_SIGNING_PUBKEY ist in installer.sh und lib/common.sh noch leer – die Signaturprüfung ist für Clients nicht aktiv."
        echo "         Trage den Inhalt von $key.pub dort ein und signiere danach erneut."
    fi

    make_sums "$WORK/$SUMS"
    # ssh-keygen legt die Signatur als <datei>.sig neben die Datei (fragt bei Bedarf nach der Passphrase)
    ssh-keygen -Y sign -f "$key" -n "$NAMESPACE" "$WORK/$SUMS" || die "Die Signatur konnte nicht erzeugt werden. SHA256SUMS bleibt unverändert."
    [ -s "$WORK/$SUMS.sig" ] || die "Die Signatur konnte nicht erzeugt werden. SHA256SUMS bleibt unverändert."
    if [ -f "$key.pub" ]; then
        verify_sig "$(cat "$key.pub")" "$WORK/$SUMS" "$WORK/$SUMS.sig" \
            || die "Die erzeugte Signatur lässt sich nicht mit $key.pub prüfen. SHA256SUMS bleibt unverändert."
    fi

    # Erst jetzt ins Repository schreiben
    cp "$WORK/$SUMS" "$SUMS" && cp "$WORK/$SUMS.sig" "$SIG" || die "SHA256SUMS bzw. SHA256SUMS.sig konnten nicht geschrieben werden."
    echo "Signiert: $(wc -l < "$SUMS") Dateien in $SUMS, Signatur in $SIG."
    echo "Vergiss nicht, beide Dateien mit zu committen."
}

do_check() {
    local bad=0 pub_installer pub_common f hash
    local -A have_sum want_sum

    make_sums "$WORK/expected"
    [ -f "$SUMS" ] || die "$SUMS fehlt. Erzeuge sie mit: scripts/sign-release.sh --sign"

    while read -r hash f; do want_sum["$f"]="$hash"; done < "$WORK/expected"
    while read -r hash f; do have_sum["$f"]="$hash"; done < "$SUMS"

    local missing=() changed=() extra=()
    for f in "${!want_sum[@]}"; do
        if [ -z "${have_sum[$f]:-}" ]; then missing+=("$f")
        elif [ "${have_sum[$f]}" != "${want_sum[$f]}" ]; then changed+=("$f"); fi
    done
    for f in "${!have_sum[@]}"; do
        [ -n "${want_sum[$f]:-}" ] || extra+=("$f")
    done
    if [ ${#missing[@]} -gt 0 ] || [ ${#changed[@]} -gt 0 ] || [ ${#extra[@]} -gt 0 ]; then
        bad=1
        echo "FEHLER: $SUMS ist nicht aktuell. Erzeuge sie neu mit: scripts/sign-release.sh --sign"
        for f in $(printf '%s\n' "${missing[@]}" | sort); do echo "  fehlt in $SUMS:       $f"; done
        for f in $(printf '%s\n' "${changed[@]}" | sort); do echo "  Prüfsumme weicht ab:  $f"; done
        for f in $(printf '%s\n' "${extra[@]}" | sort); do echo "  Eintrag ohne Datei:   $f"; done
    else
        echo "OK: $SUMS enthält alle ${#want_sum[@]} Skripte mit korrekten Prüfsummen."
    fi

    pub_installer="$(pubkey_of installer.sh)"
    pub_common="$(pubkey_of lib/common.sh)"
    if [ "$pub_installer" != "$pub_common" ]; then
        bad=1
        echo "FEHLER: GD_SIGNING_PUBKEY ist in installer.sh und lib/common.sh unterschiedlich:"
        echo "  installer.sh:   ${pub_installer:-(leer)}"
        echo "  lib/common.sh:  ${pub_common:-(leer)}"
    fi

    if [ -z "$pub_installer" ]; then
        echo "Hinweis: GD_SIGNING_PUBKEY ist noch leer – die Signaturprüfung ist nicht aktiv, es wurden nur die Prüfsummen geprüft."
    elif ! valid_pubkey_format "$pub_installer"; then
        bad=1
        echo "FEHLER: GD_SIGNING_PUBKEY hat kein gültiges Format (erwartet: \"ssh-ed25519 AAAA... germandactyl-setup\")."
    elif [ ! -f "$SIG" ]; then
        bad=1
        echo "FEHLER: $SIG fehlt. Erzeuge sie mit: scripts/sign-release.sh --sign"
    elif verify_sig "$pub_installer" "$SUMS" "$SIG"; then
        echo "OK: Die Signatur in $SIG passt zum Public Key in installer.sh."
    else
        bad=1
        echo "FEHLER: Die Signatur in $SIG passt nicht zu $SUMS und dem Public Key in installer.sh."
        echo "        (Wurde $SUMS nach dem Signieren geändert, oder mit einem anderen Schlüssel signiert?)"
    fi

    # shellcheck disable=SC2015
    [ "$bad" -eq 0 ] && exit 0 || exit 1
}

mode=""
key="${GERMANDACTYL_SETUP_SIGNING_KEY:-$DEFAULT_KEY}"
while [ $# -gt 0 ]; do
    case "$1" in
        --sign|--check) mode="$1" ;;
        -k) shift; [ $# -gt 0 ] || die "-k erwartet den Pfad zum privaten Schlüssel."; key="$1" ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

case "$mode" in
    --sign) do_sign "$key" ;;
    --check) do_check ;;
    *) usage >&2; exit 2 ;;
esac
