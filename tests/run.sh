#!/bin/bash
# Pfad: tests/run.sh
# Einfacher Test-Runner für die reinen Funktionen von GermanDactyl Setup – ohne externe Abhängigkeiten.
# Läuft ohne root, ohne Netz und ohne whiptail. Aufruf (aus beliebigem Verzeichnis):
#   bash tests/run.sh              alle Tests
#   bash tests/run.sh dotenv       nur Testdateien, deren Name "dotenv" enthält (tests/test_*dotenv*.sh)
#
# Sandbox: lib/common.sh legt beim Laden normalerweise ein Temp-Verzeichnis (GD_TMP, samt EXIT-Trap) und eine
# Log-Datei in /var/log/germandactyl-setup an. Sind GD_TMP und GD_LOG schon gesetzt, tut die Datei das nicht.
# Deshalb legt dieser Runner beides in einem eigenen mktemp-Verzeichnis an und biegt danach die fest verdrahteten
# Pfade (GD_CONF_DIR, GD_CONF_FILE, GD_LOG_DIR, PTERO_DIR) auf die Sandbox um. TMPDIR und HOME zeigen ebenfalls
# dorthin, damit auch mktemp ohne Pfadangabe nichts außerhalb anlegt. Das Verzeichnis wird beim Beenden gelöscht.
#
# Testdateien (tests/test_*.sh) werden mit "source" in dieser Shell geladen und nutzen:
#   t_group <titel>                      Überschrift
#   t_ok   <name> <befehl> [args...]     besteht, wenn der Befehl 0 zurückgibt
#   t_no   <name> <befehl> [args...]     besteht, wenn der Befehl ungleich 0 zurückgibt
#   t_eq   <name> <erwartet> <ist>       besteht, wenn beide Zeichenketten gleich sind
#   t_fn   <datei> <funktion>            lädt eine Funktion aus einem Skript, das sich nicht einbinden lässt
#                                        (z. B. analyse.sh: verlangt root und führt den Hauptteil sofort aus)
# Ohne "set -e"/"set -u": Die Bibliotheken sind dafür nicht geschrieben, Fehlschläge prüfen t_ok/t_no/t_eq.

# Variablen wie GD_CONF_FILE oder PTERO_DIR werden erst von den eingebundenen Bibliotheken benutzt
# shellcheck disable=SC2034
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
TESTS_DIR="$ROOT_DIR/tests"

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d)" || { echo "Fehler: Sandbox konnte nicht angelegt werden." >&2; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT
export TMPDIR="$SANDBOX" HOME="$SANDBOX/home"
mkdir -p "$HOME" "$SANDBOX/bin"
export GD_TMP="$SANDBOX/tmp" GD_LOG="$SANDBOX/test.log"
mkdir -p "$GD_TMP"
unset GD_LIB_DIR GD_LOCAL_DIR GD_HEADLESS GD_COMMON_LOADED

# ---------------------------------------------------------------------------
# Test-Funktionen
# ---------------------------------------------------------------------------
T_RUN=0
T_FAIL=0
T_FAILED=()

t_group() {
    echo ""
    echo "$1"
}

t__pass() {
    T_RUN=$((T_RUN + 1))
    echo "  ok    $1"
}

t__fail() {
    # t__fail <name> [detail...]
    local name="$1"
    shift
    T_RUN=$((T_RUN + 1))
    T_FAIL=$((T_FAIL + 1))
    T_FAILED+=("$name")
    echo "  FEHLER  $name"
    [ $# -gt 0 ] && printf '          %s\n' "$@"
    return 0
}

t_ok() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then t__pass "$name"; else t__fail "$name" "Befehl schlug fehl (erwartet: Erfolg): $*"; fi
}

t_no() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then t__fail "$name" "Befehl war erfolgreich (erwartet: Fehler): $*"; else t__pass "$name"; fi
}

t_eq() {
    if [ "$2" = "$3" ]; then t__pass "$1"; else t__fail "$1" "erwartet: [$2]" "erhalten: [$3]"; fi
}

t_fn() {
    # t_fn <datei relativ zum Repo> <funktion> – übernimmt die Definition einer Funktion aus einem Skript.
    # Einzeilige ("name() { ...; }") und mehrzeilige Funktionen (Ende: "}" am Zeilenanfang) werden erkannt.
    local src="$ROOT_DIR/$1" name="$2" code
    code="$(awk -v n="$name" '
        !p && index($0, n "() {") == 1 { p = 1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next }
        p { print; if ($0 ~ /^\}/) exit }' "$src")"
    if [ -z "$code" ]; then
        t__fail "Funktion $name in $1 gefunden"
        return 1
    fi
    eval "$code"
}

# ---------------------------------------------------------------------------
# Bibliotheken laden (nur Funktionsdefinitionen, keine Seiteneffekte)
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$ROOT_DIR/lib/common.sh"
GD_CONF_DIR="$SANDBOX/conf"
GD_CONF_FILE="$GD_CONF_DIR/setup.conf"
GD_LOG_DIR="$SANDBOX/log"
PTERO_DIR="$SANDBOX/pterodactyl"
# shellcheck source=/dev/null
. "$ROOT_DIR/lib/germandactyl.sh"
# shellcheck source=/dev/null
. "$ROOT_DIR/lib/panel.sh"
# common.sh stellt dem PATH die System-Verzeichnisse voran; Stub-Programme der Tests haben trotzdem Vorrang
PATH="$SANDBOX/bin:$PATH"

# ---------------------------------------------------------------------------
# Ausführen
# ---------------------------------------------------------------------------
echo "GermanDactyl Setup – Tests (Sandbox: $SANDBOX)"

t_group "Sandbox"
t_eq "GD_TMP liegt in der Sandbox" "$SANDBOX/tmp" "$GD_TMP"
t_eq "GD_CONF_DIR liegt in der Sandbox" "$SANDBOX/conf" "$GD_CONF_DIR"
t_eq "GD_LOG liegt in der Sandbox" "$SANDBOX/test.log" "$GD_LOG"
t_ok "Funktionen aus common, germandactyl und panel geladen" declare -F gd_version_ge gd_patch_latest gd_certbot_conf_rewrite

pattern="${1:-}"
found=0
for f in "$TESTS_DIR"/test_*"$pattern"*.sh; do
    [ -f "$f" ] || continue
    found=1
    # shellcheck disable=SC1090
    . "$f"
done
[ "$found" -eq 1 ] || { echo "Keine Testdatei für das Muster '$pattern' gefunden."; exit 2; }

echo ""
echo "----------------------------------------"
if [ "$T_FAIL" -eq 0 ]; then
    echo "Alle $T_RUN Tests bestanden."
    exit 0
fi
echo "$T_FAIL von $T_RUN Tests fehlgeschlagen:"
printf '  - %s\n' "${T_FAILED[@]}"
exit 1
