# Welche Kleidio-Version startet? (24.10.2026, Kleidio 24/7 Phase P1, Selbst-Update.) start.sh lädt diese Datei mit „.“ und
# ruft kleidio_app_waehlen <App im Image> auf; danach steht in KLEIDIO_APP die App, die gestartet wird, und in KLEIDIO_LAUF die
# Version aus $KLEIDIO_DATEN/app (leer: Image). Nur POSIX sh, coreutils (sort -V), tar und openssl aus dem Image.
#
# Das Selbst-Update der App (src/runtime/server-update.js) legt je Version nach $KLEIDIO_DATEN/app/<version>:
#   Kleidio-<version>-linux-<arch>.tar.gz   das Archiv aus dem Release, unverändert
#   kleidio-signatur.json                   die Signatur-Datei des Releases (zum Nachsehen)
#   signatur.txt                            drei Zeilen: Dateiname, sha512 (Base64), Ed25519-Signatur (Base64) des Archivs
# und schreibt die Version in $KLEIDIO_DATEN/app/aktuell.
#
# Security-Review 24.10.2026 (Fund 3): /data ist für den App-Nutzer schreibbar. Darum glaubt dieses Skript nichts, was dort
# liegt, und prüft bei JEDEM Start neu: Archiv in den Laufordner kopieren (danach ändert es niemand mehr), sha512 mit openssl
# rechnen, die Nachricht genau wie update-signatur.js bilden („kleidio-update\n1\n<version>\n<datei>\n<sha512>“, ohne
# Zeilenumbruch am Ende) und die Signatur mit dem öffentlichen Schlüssel aus dem Image prüfen (release-key.pem neben der App,
# gehört root). Erst dann frisch entpacken nach $KLEIDIO_LAUF_ORDNER/<version> (Standard /tmp/kleidio-run, also das
# Dateisystem des Containers, nicht /data) und von dort starten. Scheitert die Prüfung, wird die Version gesperrt und das Image
# startet.
# Entpacken mit tar aus dem Image statt eines eigenen Prüfskripts: ohne Node gibt es in sh nichts Besseres, und tar bekommt
# nur Archive, deren Signatur schon stimmt. Davor trotzdem die Liste geprüft (nur Dateien und Ordner, kein absoluter Pfad,
# kein ..), entpackt mit --no-same-owner --no-same-permissions, danach setuid, setgid und Schreibrechte für andere entfernt.
#
# Weiter gilt:
#   - Ohne kleidio-version im Image (lokal gebaut) bleibt $KLEIDIO_DATEN/app unbenutzt (Fund 10).
#   - Gestartet wird die Version aus aktuell nur, wenn sie neuer ist als die im Image. Ist das Image so neu oder neuer (neues
#     Image gezogen), startet das Image; die App räumt dann auf.
#   - Jeder Start einer Version aus app/ zählt in app/fehlstarts („<version> <anzahl>“). Läuft sie 90 Sekunden, löscht die App
#     die Datei. Steht dort schon 3, startete sie dreimal nicht: Rückfall auf app/vorige (falls gültig), sonst auf das Image,
#     und die Version kommt in app/gesperrt (das Selbst-Update lädt sie nie wieder).
#   - KLEIDIO_SELBST_UPDATE=0: immer das Image, app/ bleibt unberührt.
# Versionen landen nur in Pfaden, wenn sie aus Ziffern, Buchstaben, Punkt und Bindestrich bestehen (kein /, kein ..).

kleidio_log() { echo "kleidio-start: $*" >&2; }

# wahr, wenn $1 eine brauchbare Version ist (z. B. 0.2.0-beta.106)
kleidio_version_ok() {
  case "$1" in
    "" | *[!0-9A-Za-z.-]* | *..* | [!0-9]* | *. | *-) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# wahr, wenn $1 neuer ist als $2 (wie semver: beta.16 nach beta.9, 0.2.0 nach 0.2.0-beta.16)
kleidio_neuer_als() {
  [ "$1" = "$2" ] && return 1
  _ka=${1%%-*}
  _kb=${2%%-*}
  if [ "$_ka" != "$_kb" ]; then
    [ "$(printf '%s\n%s\n' "$_ka" "$_kb" | sort -V | tail -n 1)" = "$_ka" ]
    return
  fi
  case "$1" in *-*) ;; *) return 0 ;; esac
  case "$2" in *-*) ;; *) return 1 ;; esac
  _ka=${1#*-}
  _kb=${2#*-}
  [ "$(printf '%s\n%s\n' "$_ka" "$_kb" | sort -V | tail -n 1)" = "$_ka" ]
}

# Version aus <ordner>/kleidio-version (leer, wenn es sie nicht gibt oder sie unbrauchbar ist)
kleidio_version_von() {
  [ -f "$1/kleidio-version" ] || return 0
  _kv=$(head -n 1 "$1/kleidio-version" 2>/dev/null | tr -d '\r ') || _kv=""
  if kleidio_version_ok "$_kv"; then printf '%s' "$_kv"; fi
  return 0
}

# erste Zeile einer Datei ohne Leerzeichen (leer, wenn es sie nicht gibt)
kleidio_zeile() {
  [ -f "$1" ] || return 0
  head -n 1 "$1" 2>/dev/null | tr -d '\r ' || true
}

kleidio_gesperrt() {
  [ -f "$KLEIDIO_APPS/gesperrt" ] && grep -qxF "$1" "$KLEIDIO_APPS/gesperrt"
}

kleidio_sperren() {
  if ! kleidio_gesperrt "$1"; then printf '%s\n' "$1" >> "$KLEIDIO_APPS/gesperrt" 2>/dev/null || true; fi
}

# Datei ersetzen ohne halben Zustand
kleidio_schreiben() {
  if printf '%s\n' "$2" > "$1.tmp" 2>/dev/null && mv -f "$1.tmp" "$1"; then return 0; fi
  kleidio_log "$1 nicht geschrieben"
  return 0
}

# Architektur wie im Archivnamen (x64, arm64)
kleidio_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

# Version $1 aus app/ prüfen und frisch in den Laufordner entpacken. $2: Ordner der App im Image (dort liegt release-key.pem).
kleidio_pruefen_und_entpacken() {
  _pv="$1"
  _schluessel="$2/release-key.pem"
  _arch=$(kleidio_arch) || { kleidio_log "Prozessor $(uname -m) unbekannt"; return 1; }
  _datei="Kleidio-$_pv-linux-$_arch.tar.gz"
  _quelle="$KLEIDIO_APPS/$_pv"
  [ -f "$_quelle/$_datei" ] || { kleidio_log "$_datei fehlt"; return 1; }
  [ -f "$_quelle/signatur.txt" ] || { kleidio_log "signatur.txt fehlt"; return 1; }
  [ -f "$_schluessel" ] || { kleidio_log "release-key.pem fehlt im Image"; return 1; }
  command -v openssl > /dev/null 2>&1 || { kleidio_log "openssl fehlt im Image"; return 1; }
  command -v tar > /dev/null 2>&1 || { kleidio_log "tar fehlt im Image"; return 1; }
  case "$KLEIDIO_LAUF_ORDNER" in
    /*/kleidio-run) ;;
    *) kleidio_log "KLEIDIO_LAUF_ORDNER muss ein absoluter Pfad auf /kleidio-run sein"; return 1 ;;
  esac
  _sdatei=$(sed -n 1p "$_quelle/signatur.txt" | tr -d '\r')
  _ssig=$(sed -n 3p "$_quelle/signatur.txt" | tr -d '\r ')
  [ "$_sdatei" = "$_datei" ] || { kleidio_log "signatur.txt gilt für eine andere Datei"; return 1; }
  case "$_ssig" in "" | *[!A-Za-z0-9+/=]*) kleidio_log "Signatur unlesbar"; return 1 ;; esac

  rm -rf "$KLEIDIO_LAUF_ORDNER"
  mkdir -p "$KLEIDIO_LAUF_ORDNER/pruefung" || return 1
  chmod 700 "$KLEIDIO_LAUF_ORDNER"
  _p="$KLEIDIO_LAUF_ORDNER/pruefung"
  # Kopie zuerst: geprüft und entpackt wird genau diese Datei, nicht die in /data.
  cp "$_quelle/$_datei" "$_p/archiv.tar.gz" || return 1
  _ist=$(openssl dgst -sha512 -binary "$_p/archiv.tar.gz" | openssl base64 -A) || return 1
  printf 'kleidio-update\n1\n%s\n%s\n%s' "$_pv" "$_datei" "$_ist" > "$_p/nachricht" || return 1
  printf '%s' "$_ssig" | openssl base64 -d -A > "$_p/signatur" 2> /dev/null || return 1
  if ! openssl pkeyutl -verify -pubin -inkey "$_schluessel" -rawin -in "$_p/nachricht" -sigfile "$_p/signatur" > /dev/null 2>&1; then
    kleidio_log "Signatur von $_datei ungültig"
    return 1
  fi
  # Liste: nur Dateien und Ordner, kein absoluter Pfad, kein .., kein Backslash.
  tar -tvzf "$_p/archiv.tar.gz" > "$_p/liste" 2> /dev/null || { kleidio_log "Archiv unlesbar"; return 1; }
  if grep -q '^[^-d]' "$_p/liste"; then kleidio_log "Archiv enthält Links oder Geräte"; return 1; fi
  tar -tzf "$_p/archiv.tar.gz" > "$_p/namen" 2> /dev/null || return 1
  if grep -Eq '^/|(^|/)\.\.(/|$)|\\' "$_p/namen"; then kleidio_log "Archiv mit Pfad außerhalb"; return 1; fi
  mkdir "$KLEIDIO_LAUF_ORDNER/$_pv" || return 1
  tar -xzf "$_p/archiv.tar.gz" -C "$KLEIDIO_LAUF_ORDNER/$_pv" --no-same-owner --no-same-permissions 2> /dev/null || { kleidio_log "Entpacken gescheitert"; return 1; }
  chmod -R u-s,g-s,go-w "$KLEIDIO_LAUF_ORDNER/$_pv" || return 1
  rm -rf "$_p"
  [ -x "$KLEIDIO_LAUF_ORDNER/$_pv/kleidio" ] || { kleidio_log "Archiv ohne App"; return 1; }
  [ "$(kleidio_version_von "$KLEIDIO_LAUF_ORDNER/$_pv")" = "$_pv" ] || { kleidio_log "Archiv trägt eine andere Version"; return 1; }
  return 0
}

kleidio_app_waehlen() {
  KLEIDIO_APP="$1"
  KLEIDIO_LAUF=""
  KLEIDIO_APPS="$KLEIDIO_DATEN/app"
  KLEIDIO_LAUF_ORDNER="${KLEIDIO_LAUF_ORDNER:-/tmp/kleidio-run}"
  [ "${KLEIDIO_SELBST_UPDATE:-1}" = "1" ] || return 0
  [ -f "$KLEIDIO_APPS/aktuell" ] || return 0
  _bild=$(dirname "$1")
  _bildv=$(kleidio_version_von "$_bild")
  if [ -z "$_bildv" ]; then
    kleidio_log "Image ohne kleidio-version (lokal gebaut): Versionen aus $KLEIDIO_APPS bleiben unbenutzt"
    return 0
  fi
  _v=$(kleidio_zeile "$KLEIDIO_APPS/aktuell")
  _runde=0
  while [ "$_runde" -lt 3 ]; do
    _runde=$((_runde + 1))
    if ! kleidio_version_ok "$_v" || [ ! -d "$KLEIDIO_APPS/$_v" ]; then
      kleidio_log "Version aus $KLEIDIO_APPS/aktuell ist nicht vollständig, starte das Image"
      return 0
    fi
    if ! kleidio_neuer_als "$_v" "$_bildv"; then
      kleidio_log "Image hat $_bildv, so neu wie $_v oder neuer, starte das Image"
      return 0
    fi
    _n=0
    if [ -f "$KLEIDIO_APPS/fehlstarts" ]; then
      _fv=""
      _fn=""
      read -r _fv _fn < "$KLEIDIO_APPS/fehlstarts" || true
      if [ "$_fv" = "$_v" ]; then
        case "$_fn" in "" | *[!0-9]*) _n=0 ;; *) _n=$_fn ;; esac
      fi
    fi
    if kleidio_gesperrt "$_v"; then _n=3; fi
    if [ "$_n" -lt 3 ]; then
      if ! kleidio_pruefen_und_entpacken "$_v" "$_bild"; then
        kleidio_log "Prüfung von Kleidio $_v fehlgeschlagen: gesperrt, starte das Image"
        kleidio_sperren "$_v"
        rm -f "$KLEIDIO_APPS/aktuell" "$KLEIDIO_APPS/vorige" "$KLEIDIO_APPS/fehlstarts"
        rm -rf "$KLEIDIO_LAUF_ORDNER"
        return 0
      fi
      kleidio_schreiben "$KLEIDIO_APPS/fehlstarts" "$_v $((_n + 1))"
      KLEIDIO_APP="$KLEIDIO_LAUF_ORDNER/$_v/kleidio"
      KLEIDIO_LAUF="$_v"
      kleidio_log "starte Kleidio $_v (Signatur geprüft, Start $((_n + 1)) seit dem Update)"
      return 0
    fi
    # Rückfall: dreimal nicht gestartet
    kleidio_log "Kleidio $_v startete dreimal nicht, zurück auf die vorige Version"
    kleidio_sperren "$_v"
    _vorige=$(kleidio_zeile "$KLEIDIO_APPS/vorige")
    rm -f "$KLEIDIO_APPS/vorige" "$KLEIDIO_APPS/fehlstarts"
    if kleidio_version_ok "$_vorige" && [ "$_vorige" != "$_v" ] && ! kleidio_gesperrt "$_vorige"; then
      kleidio_schreiben "$KLEIDIO_APPS/aktuell" "$_vorige"
      _v="$_vorige"
      continue
    fi
    rm -f "$KLEIDIO_APPS/aktuell"
    kleidio_log "starte das Image"
    return 0
  done
  return 0
}
