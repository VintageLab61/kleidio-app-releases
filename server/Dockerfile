# Kleidio im Server-Modus (24.10.2026, Kleidio 24/7 Phase P0, Anlass Max/ARIEL: eigener Server oder eigener Docker, eigene
# Infrastruktur, nicht unsere). Läuft ohne Bildschirm (Xvfb), als Nutzer ohne root, Daten im Volume /data.
#
# P1 (24.10.2026): Das fertige Image baut die GitHub Action im Releases-Repo (server-image.yml) für linux/amd64 und linux/arm64
# aus den signierten Linux-Archiven des Releases und legt es als ghcr.io/vintagelab61/kleidio-server ab. Sie entpackt die
# Archive nach dist/linux-unpacked (x64) und dist/linux-arm64-unpacked (arm64), also an dieselben Stellen wie electron-builder
# hier im Repo. BuildKit wählt die passende Stufe über TARGETARCH (Docker 23 und neuer nimmt BuildKit von selbst).
#
# Lokal bauen aus dem Repo-Ordner, nachdem der Linux-Build liegt:
#   npm run paketieren:linux            (arm64-Rechner: npm run paketieren:linux-arm64)
#   docker build -f server/Dockerfile -t kleidio-server .
# Basis per Digest festgelegt (Security-Review 24.10.2026, Fund 8): dasselbe Debian für jeden Bau, bis wir es bewusst anheben.
ARG TARGETARCH
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS basis

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates openssl tini xvfb xauth fonts-liberation fonts-noto-color-emoji \
      libgtk-3-0t64 libnss3 libnspr4 libasound2t64 libgbm1 libdrm2 libxkbcommon0 libxss1 libxshmfence1 \
      libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libxcomposite1 libxdamage1 libxrandr2 libxfixes3 libxtst6 \
      libx11-xcb1 libxcb-dri3-0 libpango-1.0-0 libcairo2 libglib2.0-0t64 libdbus-1-3 libexpat1 libuuid1 libsecret-1-0 \
      libnotify4 libgl1 libegl1 \
 && rm -rf /var/lib/apt/lists/*

# Nutzer ohne root. Feste UID, damit ein gemountetes Verzeichnis passend vergeben werden kann (chown 10001 ordner).
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin kleidio \
 && mkdir -p /data /opt/kleidio \
 && chown kleidio:kleidio /data

# Der Build je Architektur. KLEIDIO_BUILD überschreibt den Ordner (nur für Sonderfälle).
FROM basis AS app-amd64
ARG KLEIDIO_BUILD=dist/linux-unpacked
COPY ${KLEIDIO_BUILD}/ /opt/kleidio/

FROM basis AS app-arm64
ARG KLEIDIO_BUILD=dist/linux-arm64-unpacked
COPY ${KLEIDIO_BUILD}/ /opt/kleidio/

FROM app-${TARGETARCH}
COPY server/start.sh /opt/kleidio/start.sh
COPY server/app-wahl.sh /opt/kleidio/app-wahl.sh
# Öffentlicher Release-Schlüssel für app-wahl.sh: prüft bei jedem Start die Signatur einer Version aus /data/app (openssl).
COPY server/release-key.pem /opt/kleidio/release-key.pem
# Kein setuid-Helfer: die Chromium-Sandbox läuft über User-Namespaces (seccomp-kleidio.json erlaubt sie), chrome-sandbox als
# setuid-root bräuchte der Container nicht und soll ihn auch nicht haben. Alles unter /opt/kleidio gehört root, die App kann
# sich dort nicht selbst ändern. Selbst-Updates liegen als signiertes Archiv in /data/app; start.sh prüft es bei jedem Start
# mit dem Schlüssel von hier und entpackt es frisch nach /tmp/kleidio-run (app-wahl.sh).
RUN chmod 0755 /opt/kleidio/kleidio /opt/kleidio/start.sh \
 && chmod 0644 /opt/kleidio/app-wahl.sh /opt/kleidio/release-key.pem \
 && chmod 0755 /opt/kleidio/chrome-sandbox \
 && chown -R root:root /opt/kleidio

ARG KLEIDIO_VERSION=
LABEL org.opencontainers.image.title="Kleidio Server" \
      org.opencontainers.image.description="Kleidio rund um die Uhr auf deinem eigenen Server" \
      org.opencontainers.image.url="https://kleidio.com" \
      org.opencontainers.image.source="https://github.com/VintageLab61/kleidio-app-releases" \
      org.opencontainers.image.version="${KLEIDIO_VERSION}"

ENV KLEIDIO_SERVER=1 \
    KLEIDIO_DATEN=/data \
    KLEIDIO_APP=/opt/kleidio/kleidio \
    KLEIDIO_SELBST_UPDATE=1

USER kleidio
WORKDIR /home/kleidio
VOLUME ["/data"]

# Gesund, solange die App ihren Stand schreibt (jede Minute, auch während sie auf das Koppeln wartet).
HEALTHCHECK --interval=60s --timeout=5s --start-period=120s --retries=3 \
  CMD test -n "$(find /data/server-stand.json -mmin -3 2>/dev/null)" || exit 1

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/kleidio/start.sh"]
