#!/bin/sh
# Kleidio im Server-Modus starten (24.10.2026, Kleidio 24/7 Phase P0, Anlass Max/ARIEL). Startet einen unsichtbaren Bildschirm
# (Xvfb) und danach die App mit exec, damit SIGTERM (docker stop, systemctl stop) direkt bei Kleidio ankommt und die App sauber
# beendet. xvfb-run -a reicht das Signal nicht weiter (die App liefe ohne Aufräumen weiter oder stürbe mitten im Schreiben),
# darum das eigene Skript. Auf einem VPS ohne Docker geht auch: xvfb-run -a env KLEIDIO_SERVER=1 KLEIDIO_DATEN=... ./kleidio
#
# Selbst-Update (24.10.2026, Kleidio 24/7 Phase P1): Welche Version startet, entscheidet app-wahl.sh neben diesem Skript, die
# neueste aus $KLEIDIO_DATEN/app, deren Signatur bei diesem Start mit openssl stimmt (frisch entpackt nach /tmp/kleidio-run),
# sonst die im Image, mit Rückfall nach drei Fehlstarts. Die App lädt neue Versionen
# selbst (Signatur geprüft) und endet für den Wechsel mit Exit-Code 75; Docker (restart: unless-stopped) oder systemd
# (Restart=always) starten danach neu. Ohne app-wahl.sh startet immer die App aus KLEIDIO_APP, ohne Selbst-Update.
#
# Umgebung:
#   KLEIDIO_APP           Pfad zur App im Image (Standard /opt/kleidio/kleidio)
#   KLEIDIO_SELBST_UPDATE 0 = kein Selbst-Update, immer die App im Image (Standard 1)
#   KLEIDIO_DATEN         Datenordner (Standard /data)
#   KLEIDIO_NAME          Name in „Deine Server“ (Standard „Server <hostname>“)
#   KLEIDIO_DISPLAY       Bildschirm für Xvfb (Standard :99)
#   KLEIDIO_OHNE_SANDBOX  1 = Chromium ohne Sandbox (nur wenn der Host keine User-Namespaces erlaubt, siehe README)
set -eu

BILD_APP="${KLEIDIO_APP:-/opt/kleidio/kleidio}"
KLEIDIO_DISPLAY="${KLEIDIO_DISPLAY:-:99}"
export KLEIDIO_SERVER=1
export KLEIDIO_DATEN="${KLEIDIO_DATEN:-/data}"
if [ "${KLEIDIO_SELBST_UPDATE:-1}" = "0" ]; then KLEIDIO_SELBST_UPDATE=0; else KLEIDIO_SELBST_UPDATE=1; fi

mkdir -p "$KLEIDIO_DATEN"
WAHL="$(dirname "$0")/app-wahl.sh"
if [ -f "$WAHL" ]; then
  . "$WAHL"
  kleidio_app_waehlen "$BILD_APP"
else
  echo "app-wahl.sh fehlt neben start.sh: ohne Selbst-Update" >&2
  KLEIDIO_APP="$BILD_APP"
  KLEIDIO_LAUF=""
  KLEIDIO_SELBST_UPDATE=0
fi
# KLEIDIO_LAUF: Version aus $KLEIDIO_DATEN/app, die gerade startet (leer: Image); die App setzt danach ihren Fehlstart-Zähler zurück.
export KLEIDIO_SELBST_UPDATE KLEIDIO_LAUF

if [ ! -x "$KLEIDIO_APP" ]; then
  echo "Kleidio nicht gefunden: $KLEIDIO_APP" >&2
  exit 1
fi

nummer="${KLEIDIO_DISPLAY#:}"
rm -f "/tmp/.X${nummer}-lock" "/tmp/.X11-unix/X${nummer}" 2>/dev/null || true
Xvfb "$KLEIDIO_DISPLAY" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
i=0
while [ ! -S "/tmp/.X11-unix/X${nummer}" ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    echo "Xvfb startet nicht ($KLEIDIO_DISPLAY)" >&2
    exit 1
  fi
  sleep 0.1
done
export DISPLAY="$KLEIDIO_DISPLAY"

if [ "${KLEIDIO_OHNE_SANDBOX:-0}" = "1" ]; then
  echo "Achtung: Kleidio läuft ohne Chromium-Sandbox (KLEIDIO_OHNE_SANDBOX=1)." >&2
  set -- --no-sandbox "$@"
fi

exec "$KLEIDIO_APP" "$@"
