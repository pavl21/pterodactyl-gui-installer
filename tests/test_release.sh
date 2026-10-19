#!/bin/bash
# Pfad: tests/test_release.sh
# Tests für gd_latest_tag / gd_latest_release (lib/common.sh) und gd_patch_latest (lib/germandactyl.sh).
# Das Netz wird durch eine Funktion "curl" bzw. "gd_curl" in der Test-Shell ersetzt – es gibt keine Anfragen.
# Wird von tests/run.sh eingebunden (nicht einzeln ausführen).

# GD_PANEL_MAJOR wird unten gesetzt und von gd_latest_release gelesen
# shellcheck disable=SC2034

# Steuerung des curl-Stubs:
#   STUB_TAG_panel / STUB_TAG_other  Tag, auf den "releases/latest" weiterleitet (leer = keine Weiterleitung auf /tag/)
#   STUB_LIST                        Antwort der API-Liste (repos/pterodactyl/panel/releases?per_page=50)
#   STUB_LATEST_JSON                 Antwort von repos/<repo>/releases/latest der API
STUB_CALLS="$GD_TMP/curl.calls"
curl() {
    local a url="" repo tag
    for a in "$@"; do
        case "$a" in
            https://*) url="$a" ;;
        esac
    done
    echo "$url" >> "$STUB_CALLS"
    case "$url" in
        https://github.com/*/releases/latest)
            repo="${url#https://github.com/}"; repo="${repo%/releases/latest}"
            if [ "$repo" = "pterodactyl/panel" ]; then tag="$STUB_TAG_panel"; else tag="$STUB_TAG_other"; fi
            if [ -n "$tag" ]; then echo "https://github.com/$repo/releases/tag/$tag"; else echo "https://github.com/$repo/releases"; fi
            ;;
        https://api.github.com/repos/*/releases?per_page=*) printf '%s' "$STUB_LIST" ;;
        https://api.github.com/repos/*/releases/latest) printf '%s' "$STUB_LATEST_JSON" ;;
        *) return 22 ;;
    esac
}
_calls() { [ -f "$STUB_CALLS" ] && wc -l < "$STUB_CALLS" || echo 0; }
_calls_reset() { rm -f "$STUB_CALLS"; }

STUB_LIST='[
  {"tag_name": "v2.0.0", "name": "v2.0.0"},
  {"tag_name": "v2.0.0-beta.1"},
  {"tag_name": "v1.15.1", "name": "v1.15.1"},
  {"tag_name": "v1.15.0"},
  {"tag_name": "v1.9.0"},
  {"tag_name": "v1.11.10"},
  {"tag_name": "v1.15.1-rc.1"}
]'
STUB_LATEST_JSON='{"url": "x", "tag_name": "v1.2.3", "name": "v1.2.3"}'

# ---------------------------------------------------------------------------
t_group "gd_latest_release (Major-Filter für pterodactyl/panel)"
GD_PANEL_MAJOR=1
STUB_TAG_panel="v2.0.0"; STUB_TAG_other="v1.11.13"
_calls_reset
t_eq "Panel: neuestes Release ist 2.0.0 -> höchste 1.x (1.15.1)" 1.15.1 "$(gd_latest_release pterodactyl/panel)"
t_eq "Panel 2.0.0: es wurde die API-Liste abgefragt" 1 "$(grep -c 'releases?per_page=' "$STUB_CALLS")"
t_eq "Liste: 1.11.10 > 1.9.0 (Versionssortierung, kein Textvergleich)" 1.15.1 "$(gd_latest_release pterodactyl/panel)"

STUB_LIST='[{"tag_name": "v1.9.0"}, {"tag_name": "v1.11.10"}, {"tag_name": "v2.1.0"}]'
t_eq "Liste ohne 1.15: höchste 1.x ist 1.11.10" 1.11.10 "$(gd_latest_release pterodactyl/panel)"

STUB_LIST='[{"tag_name": "v2.0.0"}, {"tag_name": "v2.0.0-beta.1"}]'
t_no "Liste ohne passende Major-Version: Fehler" gd_latest_release pterodactyl/panel
STUB_LIST='[]'
t_no "leere Liste: Fehler" gd_latest_release pterodactyl/panel
STUB_LIST='[{"tag_name": "v2.0.0"}, {"tag_name": "v1.15.1"}]'

STUB_TAG_panel="v1.15.1"
_calls_reset
t_eq "Panel: neuestes Release ist schon 1.x -> unverändert" 1.15.1 "$(gd_latest_release pterodactyl/panel)"
_calls_reset
gd_latest_release pterodactyl/panel >/dev/null
t_eq "Panel 1.x: keine zusätzliche API-Abfrage" 1 "$(_calls)"

GD_PANEL_MAJOR=2
STUB_TAG_panel="v2.0.0"
t_eq "GD_PANEL_MAJOR=2: 2.0.0 wird zurückgegeben" 2.0.0 "$(gd_latest_release pterodactyl/panel)"
GD_PANEL_MAJOR=1

STUB_TAG_panel="v2.0.0"; STUB_TAG_other="v2.3.4"
t_eq "pterodactyl/wings: Major-Filter gilt nicht (2.3.4 unverändert)" 2.3.4 "$(gd_latest_release pterodactyl/wings)"
_calls_reset
gd_latest_release pterodactyl/wings >/dev/null
t_eq "wings: keine API-Liste abgefragt" 0 "$(grep -c 'releases?per_page=' "$STUB_CALLS" 2>/dev/null || true)"
STUB_TAG_other="v1.11.13"
t_eq "pterodactyl/wings 1.11.13" 1.11.13 "$(gd_latest_release pterodactyl/wings)"
STUB_TAG_other="v1.12.0-rc.1"
t_eq "Vorabversion mit Suffix bleibt erhalten" 1.12.0-rc.1 "$(gd_latest_release pterodactyl/wings)"
STUB_TAG_other="beta-2026-08"
t_no "Tag ohne Versionsnummer: Fehler" gd_latest_release pterodactyl/wings

# ---------------------------------------------------------------------------
t_group "gd_latest_tag"
STUB_TAG_other="v1.15.1"
t_eq "Tag mit v-Präfix" v1.15.1 "$(gd_latest_tag some/repo)"
STUB_TAG_other="beta-2026-08"
t_eq "Tag ohne Versionsnummer wird ausgegeben" beta-2026-08 "$(gd_latest_tag some/repo)"
STUB_TAG_other=""
STUB_LATEST_JSON='{"url": "x", "tag_name": "v1.2.3", "name": "v1.2.3"}'
t_eq "Rückfallebene: API liefert den Tag, wenn die Weiterleitung fehlt" v1.2.3 "$(gd_latest_tag some/repo)"
STUB_LATEST_JSON='{"message": "API rate limit exceeded"}'
t_no "ohne Weiterleitung und ohne API-Antwort: Fehler" gd_latest_tag some/repo
STUB_TAG_other="v1.0\$(touch $GD_TMP/pwned)"
STUB_LATEST_JSON='{"message": "x"}'
t_no "unzulässige Zeichen im Tag werden abgelehnt" gd_latest_tag some/repo
t_no "es wurde nichts ausgeführt" test -e "$GD_TMP/pwned"

# ---------------------------------------------------------------------------
t_group "gd_patch_latest (gd_curl als Stub)"
gd_curl() { printf '%s' "$STUB_PATCHES"; }
STUB_PATCHES='[{"name": "v1.11.2.patch"}, {"name": "v1.9.1.patch"}, {"name": "v1.15.1.patch"}, {"name": "SHA256SUMS"}, {"name": "README.md"}, {"name": "v1.12.2.patch"}]'
t_eq "höchste Patch-Version aus der Liste" 1.15.1 "$(gd_patch_latest)"
STUB_PATCHES='[{"name": "v1.9.1.patch"}, {"name": "v1.11.2.patch"}]'
t_eq "Versionssortierung: 1.11.2 > 1.9.1" 1.11.2 "$(gd_patch_latest)"
STUB_PATCHES='{"message": "API rate limit exceeded"}'
t_eq "ohne Liste: Rückfallwert GD_PATCH_FALLBACK" "$GD_PATCH_FALLBACK" "$(gd_patch_latest)"
unset -f gd_curl

unset -f curl _calls _calls_reset
unset STUB_CALLS STUB_LIST STUB_LATEST_JSON STUB_TAG_panel STUB_TAG_other STUB_PATCHES
