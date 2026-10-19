#!/bin/bash
# Pfad: lib/germandactyl.sh
# GermanDactyl: Auswahl der Panel-Version passend zu verfügbaren Übersetzungs-Patches
# und eigenständiges Anwenden des Patches (Node.js 22 + yarn, wie vom Panel vorausgesetzt).

GD_PATCH_SERVER="https://patch.germandactyl.de"
GD_PATCH_REPO="pavl21/GermanDactyl"
GD_PATCH_FALLBACK="1.15.1"   # Neueste bekannte Patch-Version – nur Rückfallwert, falls die Patch-Liste nicht abgerufen werden kann
GD_NODE_MAJOR="22"

# Prüfung der Patches: Die Prüfsumme des Patches wird mit patches/SHA256SUMS aus dem GermanDactyl-Repository
# (https://github.com/pavl21/GermanDactyl) verglichen.
GD_PATCH_CHECKSUM_BASE="https://raw.githubusercontent.com/pavl21/GermanDactyl/main/patches"

gd_patch_exists() {
    # gd_patch_exists <version> -> wahr, wenn es einen GermanDactyl-Patch gibt
    local code
    code="$(curl -s -o /dev/null -L -w '%{http_code}' --max-time 15 "$GD_PATCH_SERVER/$1")"
    [ "$code" = "200" ]
}

gd_patch_latest() {
    # Neueste Version, für die ein Patch existiert (aus dem GermanDactyl-Repository ermittelt)
    local list
    list="$(gd_curl --max-time 15 --retry 2 "https://api.github.com/repos/$GD_PATCH_REPO/contents/patches" 2>/dev/null \
        | grep -oE '"name": *"v[0-9]+\.[0-9]+\.[0-9]+\.patch"' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1)"
    if [ -n "$list" ]; then
        echo "$list"
    else
        echo "$GD_PATCH_FALLBACK"
    fi
}

gd_choose_panel_version() {
    # Setzt GD_PANEL_VERSION und GD_APPLY_PATCH (true/false) – mit Dialog, falls kein passender Patch existiert.
    local latest patch_version choice
    latest="$(gd_latest_release pterodactyl/panel)"
    if [ -z "$latest" ]; then
        gd_msg "Fehler" "Die aktuelle Pterodactyl-Version konnte nicht ermittelt werden. Prüfe die Internetverbindung (github.com)." 9 70
        return 1
    fi

    if gd_patch_exists "$latest"; then
        GD_PANEL_VERSION="$latest"
        GD_APPLY_PATCH=true
        return 0
    fi

    patch_version="$(gd_patch_latest)"
    choice=$(whiptail --title "✎ GermanDactyl – Versionsauswahl" --menu "Die neueste Pterodactyl-Version ist v$latest. Für diese Version gibt es noch keine deutsche Übersetzung (GermanDactyl).\n\nDie neueste übersetzte Version ist v$patch_version. Welche Version möchtest du installieren?" 18 78 2 \
        "1" "v$latest – aktuellste Version, Oberfläche auf Englisch" \
        "2" "v$patch_version – ältere Version, Oberfläche auf Deutsch" 3>&1 1>&2 2>&3) || return 1

    if [ "$choice" = "2" ]; then
        GD_PANEL_VERSION="$patch_version"
        GD_APPLY_PATCH=true
    else
        GD_PANEL_VERSION="$latest"
        GD_APPLY_PATCH=false
    fi
    return 0
}

gd_install_node() {
    # Node.js >= 22 sicherstellen (Distro-Paket, falls neu genug, sonst NodeSource-Repository) + yarn
    local current=0
    if command -v node >/dev/null 2>&1; then
        current="$(node -v | sed 's/^v//; s/\..*//')"
    fi
    if [ "$current" -lt "$GD_NODE_MAJOR" ]; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg || return 1
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${GD_NODE_MAJOR}.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list
        # Reste von Node aus dem Distributionspaket (v. a. Ubuntu 22.04) kollidieren mit dem NodeSource-Paket
        # ("trying to overwrite '/usr/include/node/common.gypi'")
        local old_pkgs
        old_pkgs="$(dpkg-query -W -f='${Package} ${Status}\n' libnode-dev 'libnode[0-9]*' nodejs-doc npm 2>/dev/null | awk '/install ok installed/{print $1}')"
        [ -n "$old_pkgs" ] && { gd_apt purge $old_pkgs || return 1; }
        gd_apt_update
        gd_apt install nodejs || return 1
    fi
    # "yarn" muss Yarn 1.x sein – das Ubuntu-Paket cmdtest liefert ein gleichnamiges, anderes Programm
    if ! yarn --version 2>/dev/null | grep -q '^1\.'; then
        npm install -g yarn || return 1
        hash -r
        yarn --version 2>/dev/null | grep -q '^1\.' || { echo "yarn 1.x konnte nicht eingerichtet werden (Konflikt mit dem Paket cmdtest? 'apt purge cmdtest')."; return 1; }
    fi
    return 0
}

gd_build_swap_on() {
    # Der Frontend-Build braucht viel Arbeitsspeicher. Bei weniger als 3 GB RAM+Swap
    # wird für die Dauer des Builds eine temporäre Swap-Datei angelegt.
    local total
    total="$(LC_ALL=C free -m | awk '/^Mem:/{m=$2} /^Swap:/{s=$2} END{print m+s}')"
    GD_BUILD_SWAP=""
    if [ "${total:-0}" -lt 3072 ]; then
        GD_BUILD_SWAP="/swapfile-germandactyl-build"
        # Datei zuerst mit Rechten 600 anlegen, damit sie zu keinem Zeitpunkt für alle lesbar ist
        if install -m 600 /dev/null "$GD_BUILD_SWAP" 2>/dev/null \
            && { fallocate -l 2G "$GD_BUILD_SWAP" 2>/dev/null || dd if=/dev/zero of="$GD_BUILD_SWAP" bs=1M count=2048 status=none; }; then
            chmod 600 "$GD_BUILD_SWAP"
            mkswap "$GD_BUILD_SWAP" >/dev/null && swapon "$GD_BUILD_SWAP" || { rm -f "$GD_BUILD_SWAP"; GD_BUILD_SWAP=""; }
        else
            GD_BUILD_SWAP=""
        fi
    fi
    return 0
}

gd_build_swap_off() {
    if [ -n "${GD_BUILD_SWAP:-}" ]; then
        swapoff "$GD_BUILD_SWAP" 2>/dev/null
        rm -f "$GD_BUILD_SWAP"
        GD_BUILD_SWAP=""
    fi
    return 0
}

gd_patch_verify() {
    # gd_patch_verify <version> <patch-datei> – lädt patches/SHA256SUMS und vergleicht die Prüfsumme der
    # heruntergeladenen Patch-Datei (v<version>.patch) mit dem Eintrag der Liste.
    # Ohne passende Prüfsumme wird der Patch nicht angewendet (Rückgabe 1, Grund auf stdout).
    # Der Patch ändert PHP- und JavaScript-Dateien des Panels und läuft anschließend im Build bzw. im Webserver –
    # eine fehlerhafte oder unvollständige Datei soll deshalb nie angewendet werden.
    local version="$1" file="$2" dir="$GD_TMP/patch-pruefsumme" name expected actual
    rm -rf "$dir"
    mkdir -p "$dir" && chmod 700 "$dir" || return 1
    if ! gd_curl --proto '=https' --proto-redir '=https' --max-time 30 -o "$dir/SHA256SUMS" "$GD_PATCH_CHECKSUM_BASE/SHA256SUMS"; then
        echo "Die Prüfsummenliste konnte nicht geladen werden."
        return 1
    fi
    name="v${version}.patch"
    expected="$(awk -v f="$name" '$2 == f || $2 == "*" f { print $1; exit }' "$dir/SHA256SUMS")"
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Für $name gibt es keine Prüfsumme."
        return 1
    fi
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
    if [ "$actual" != "$expected" ]; then
        echo "Die Prüfsumme von $name stimmt nicht mit der Liste überein."
        return 1
    fi
    echo "Prüfsumme von $name ist gültig ($actual)."
    return 0
}

gd_patch_fuzzy_file() {
    # gd_patch_fuzzy_file <patch> <datei> <rej_dir> <vor-reject-dir> – wendet nur den Abschnitt dieser Datei aus dem
    # Patch mit Unschärfe an (patch, --fuzz=3). Der Versuch startet vom Stand VOR "git apply --reject" (pre_dir): Hätte
    # git schon einzelne Hunks dieser Datei angewendet, würde patch sie als "bereits angewendet" melden und den
    # abgelehnten Hunk nicht mit ihnen zusammen anwenden. Der Stand nach dem Reject-Lauf wird vorher als
    # <rej_dir>/original gesichert und bei Misserfolg wiederhergestellt.
    # Rückgabe 0 = angewendet (.rej der Datei wird entfernt), 1 = nicht angewendet.
    local patch="$1" f="$2" rej_dir="$3" pre_dir="$4"
    [ -f "$f" ] && [ -f "$pre_dir/$f" ] || return 1
    mkdir -p "$rej_dir/original/$(dirname "$f")" && cp -a "$f" "$rej_dir/original/$f" || return 1
    cp -a "$pre_dir/$f" "$f" || return 1
    awk -v f="$f" '/^diff --git /{p = ($0 == "diff --git a/" f " b/" f)} p' "$patch" > "$GD_TMP/einzel.patch"
    if patch -p1 --forward --fuzz=3 --no-backup-if-mismatch -r /dev/null -s -i "$GD_TMP/einzel.patch" >> "$GD_LOG" 2>&1; then
        rm -f "$rej_dir/$f.rej"
        return 0
    fi
    # Misserfolg: Datei auf den Stand nach dem Reject-Lauf zurücksetzen, entstandene .orig/.rej entfernen
    cp -a "$rej_dir/original/$f" "$f"
    rm -f "$f.orig" "$f.rej"
    return 1
}

gd_patch_apply() {
    # gd_patch_apply <version> [panel-pfad] – lädt den Patch, prüft die Prüfsumme und wendet ihn an.
    # Rückgabe: 0 = Patch (ggf. teilweise) angewendet oder bereits vorhanden, 1 = Download/Prüfung/Anwendung komplett fehlgeschlagen
    local version="$1" dir="${2:-$PTERO_DIR}"
    local patch="$GD_TMP/germandactyl.patch" backup_root="/var/backups/germandactyl"
    local stamp created f old_dir rej_dir pre_dir out rc rejected n remaining saved=false
    local opts=(--ignore-whitespace --ignore-space-change)
    GD_PATCH_FUZZY_FILES=""
    GD_PATCH_REJ_DIR=""
    cd "$dir" || return 1
    gd_curl --proto '=https' --proto-redir '=https' "$GD_PATCH_SERVER/$version" -o "$patch" || return 1
    # Ungeprüfte Patches werden nie angewendet, eine Option zum Überspringen gibt es bewusst nicht
    if ! gd_patch_verify "$version" "$patch"; then
        echo "Prüfsumme des Patches ungültig – wird aus Sicherheitsgründen nicht angewendet"
        rm -f "$patch"
        return 1
    fi
    stamp="$(date +%Y%m%d-%H%M%S)"

    # Ist der Patch bereits vollständig angewendet (z. B. Reparatur ohne Panel-Update), gibt es nichts zu tun
    if git apply "${opts[@]}" --reverse --check "$patch" >/dev/null 2>&1; then
        echo "Die Übersetzung v$version ist bereits angewendet, nichts zu tun."
        return 0
    fi

    # Vom Patch neu angelegte Dateien (v. a. resources/lang/de/* und resources/lang/de.json) können noch von
    # einer früheren Übersetzung stammen. git apply bricht dann mit "already exists in working directory" ab,
    # ohne eine .rej-Datei anzulegen – die Übersetzung bliebe stillschweigend veraltet. Sie werden daher vorher gesichert.
    created="$(git apply --summary "$patch" 2>/dev/null | sed -n 's/^ create mode [0-7]* //p')"
    old_dir="$backup_root/alte-uebersetzung-${version}-${stamp}"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -e "$f" ] || [ -L "$f" ]; then
            mkdir -p "$old_dir" && cp -a --parents "$f" "$old_dir/" && rm -f "$f" && saved=true
            echo "Alte Übersetzungsdatei gesichert und entfernt: $f"
        fi
    done <<< "$created"
    if $saved; then
        chmod 700 "$backup_root" "$old_dir" 2>/dev/null
        echo "Sicherung der alten Übersetzung: $old_dir"
    fi

    # Normaler Fall: Der Patch passt komplett
    if git apply "${opts[@]}" --check "$patch" >/dev/null 2>&1; then
        git apply "${opts[@]}" "$patch" || return 1
        return 0
    fi

    # Der Patch passt nicht komplett (Addon/Theme installiert oder Panel-Version weicht ab):
    # passende Teile anwenden, den Rest als .rej-Dateien ablegen
    # Stand aller vom Patch berührten Dateien vor dem --reject-Lauf sichern (Ausgangsbasis für den unscharfen Versuch)
    pre_dir="$GD_TMP/vor-reject"
    rm -rf "$pre_dir"
    mkdir -p "$pre_dir"
    git apply --numstat "$patch" 2>/dev/null | cut -f3 | while IFS= read -r f; do
        [ -f "$f" ] && mkdir -p "$pre_dir/$(dirname "$f")" && cp -a "$f" "$pre_dir/$f"
    done
    out="$(git apply "${opts[@]}" --reject -v "$patch" 2>&1)"
    rc=$?
    echo "$out"
    find . -path ./node_modules -prune -o -name '*.orig' -exec rm -f {} +
    rejected="$(find . -path ./node_modules -prune -o -name '*.rej' -print | sed 's#^\./##' | sort)"
    if [ -n "$rejected" ]; then
        # Rejects nicht löschen, sondern mit Verzeichnisstruktur sichern (zur manuellen Nacharbeit)
        rej_dir="$backup_root/rejects-${version}-${stamp}"
        mkdir -p "$rej_dir" && chmod 700 "$backup_root" "$rej_dir" 2>/dev/null
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            mkdir -p "$rej_dir/$(dirname "$f")" && mv -f "$f" "$rej_dir/$f"
        done <<< "$rejected"
        rejected="$(sed 's#\.rej$##' <<< "$rejected")"
        GD_PATCH_REJ_DIR="$rej_dir"
        echo "Folgende Dateien passen nicht (vollständig) zum Patch (Kontext weicht ab, z. B. durch den Blueprint-Lauf):"
        echo "$rejected"
        echo "Die nicht angewendeten Teile liegen in: $rej_dir"

        # Zweiter Versuch für jede abgelehnte Datei mit "patch" und Unschärfe. Dabei wird nur der Abschnitt dieser
        # Datei aus dem Patch verwendet. Vorher wird der Stand vor dem Versuch gesichert (GD_PATCH_REJ_DIR/original).
        command -v patch >/dev/null 2>&1 || gd_apt_install patch >> "$GD_LOG" 2>&1
        mkdir -p "$rej_dir/original"
        remaining=""
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if gd_patch_fuzzy_file "$patch" "$f" "$rej_dir" "$pre_dir"; then
                GD_PATCH_FUZZY_FILES+="$f"$'\n'
                gd_log "Mit Unschärfe angewendet: $f"
            else
                remaining+="$f"$'\n'
                gd_log "Nicht angewendet: $f"
            fi
        done <<< "$rejected"

        n="$(printf '%s\n' "$remaining" | grep -c .)"
        if [ "$n" -gt 0 ]; then
            printf '%s\n' "$remaining" | grep . > "$rej_dir/LISTE.txt"
            echo "Weiterhin nicht übersetzt ($n Datei(en), Liste: $rej_dir/LISTE.txt):"
            grep . "$rej_dir/LISTE.txt"
            GD_WARNINGS="${GD_WARNINGS:+$GD_WARNINGS\n}⚠ Die deutsche Übersetzung ist unvollständig: $n Datei(en) konnten nicht übersetzt werden und bleiben teilweise englisch (Liste: $rej_dir/LISTE.txt)."
        else
            echo "Alle abgelehnten Dateien wurden mit Unschärfe angewendet."
        fi
        return 0
    fi
    if [ $rc -ne 0 ]; then
        if grep -qE '^Appl(ied|ying) patch' <<< "$out"; then
            # Teilweise angewendet, ohne dass .rej-Dateien entstanden sind (z. B. Dateien fehlen)
            GD_WARNINGS="${GD_WARNINGS:+$GD_WARNINGS\n}⚠ Die deutsche Übersetzung ist unvollständig: Einige Dateien konnten nicht übersetzt werden (Details im Log)."
            return 0
        fi
        echo "Die Übersetzung v$version konnte nicht angewendet werden."
        return 1
    fi
    return 0
}

gd_panel_build() {
    # Frontend des Panels neu bauen (nötig, damit die Übersetzung sichtbar wird)
    local dir="${1:-$PTERO_DIR}" rc=0
    cd "$dir" || return 1
    # Wie Blueprint: Ältere Build-Abhängigkeiten nutzen Hash-Verfahren, die OpenSSL 3 (Node >= 17)
    # nur mit dem Legacy-Provider erlaubt – sonst "error:0308010C:digital envelope routines::unsupported"
    export NODE_OPTIONS="--openssl-legacy-provider"
    gd_build_swap_on
    yarn install --frozen-lockfile --network-timeout 600000 || yarn install --network-timeout 600000 || rc=1
    [ $rc -eq 0 ] && { yarn run build:production || rc=1; }
    gd_build_swap_off
    [ $rc -eq 0 ] || return 1
    # node_modules wird nur behalten, wenn Blueprint es für Erweiterungen benötigt (spart sonst ~500 MB)
    [ -f "$dir/.blueprint/extensions/blueprint/private/db/is_installed" ] || rm -rf node_modules
    php artisan view:clear
    php artisan optimize:clear
    chown -R www-data:www-data "$dir"
}

gd_panel_build_retry() {
    # Wie gd_panel_build. Schlägt der Build fehl und wurden Dateien nur mit Unschärfe gepatcht, werden genau diese
    # auf den Stand vor dem unscharfen Patch zurückgesetzt und der Build wird einmal wiederholt.
    local f names="" reverted=0
    gd_panel_build && return 0
    [ -n "${GD_PATCH_FUZZY_FILES:-}" ] || return 1
    gd_log "Build fehlgeschlagen – unscharf gepatchte Dateien zurückgesetzt, Build wird wiederholt"
    cd "$PTERO_DIR" || return 1
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        cp -a "$GD_PATCH_REJ_DIR/original/$f" "$f" || return 1
        names+="$f"$'\n'
        reverted=$((reverted + 1))
    done <<< "$GD_PATCH_FUZZY_FILES"
    printf '%s' "$names" >> "$GD_PATCH_REJ_DIR/LISTE.txt"
    gd_log "Zurückgesetzte Dateien (auch in $GD_PATCH_REJ_DIR/LISTE.txt): $(tr '\n' ' ' <<< "$names")"
    GD_WARNINGS="${GD_WARNINGS:+$GD_WARNINGS\n}⚠ Nach einem fehlgeschlagenen Build wurden $reverted weitere Datei(en) auf ihren Stand ohne Unschärfe zurückgesetzt und bleiben englisch (Liste: $GD_PATCH_REJ_DIR/LISTE.txt)."
    GD_PATCH_FUZZY_FILES=""
    gd_panel_build
}

gd_germandactyl_steps() {
    # gd_germandactyl_steps <start-prozent> – Patch-Schritte innerhalb eines offenen Fortschrittsbalkens
    local p="${1:-85}"
    gd_step "$p" "GermanDactyl: Node.js ${GD_NODE_MAJOR} und yarn werden vorbereitet..." gd_install_node
    gd_step $((p + 2)) "GermanDactyl: Deutsche Übersetzung (v$GD_PANEL_VERSION) wird angewendet..." gd_patch_apply "$GD_PANEL_VERSION"
    gd_step $((p + 4)) "GermanDactyl: Oberfläche wird neu gebaut, das dauert einige Minuten..." gd_panel_build_retry
    gd_conf_set GD_GERMANDACTYL "$GD_PANEL_VERSION"
}
