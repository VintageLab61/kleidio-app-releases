#!/usr/bin/env node
// Linux-Archive eines Releases prüfen, bevor die GitHub Action daraus das Docker-Image baut (24.10.2026, Kleidio 24/7 Phase P1).
// Liegt im Releases-Repo unter server/ (Kopie aus kleidio-desktop/server), aufgerufen von .github/workflows/server-image.yml:
//
//   node server/signatur-pruefen.mjs <ordner> <version>
//
// Erwartet in <ordner> kleidio-signatur.json, Kleidio-<version>-linux-x64.tar.gz und Kleidio-<version>-linux-arm64.tar.gz.
// Prüft für jedes Archiv: Eintrag in „dateien“ der Signatur-Datei, Version, Dateiname, sha512 der Datei und die Ed25519-
// Signatur mit dem öffentlichen Release-Schlüssel. Dieselbe Nachricht und derselbe Schlüssel wie in
// kleidio-desktop/src/runtime/update-signatur.js (ein Test dort vergleicht beides). Ohne Abhängigkeiten, Node 18 und neuer.
// Exit 0 nur, wenn beide Archive passen.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export const OEFFENTLICHER_SCHLUESSEL = 'MCowBQYDK2VwAyEAF+4MmRKBfhLBw/Sy52zj9ZlhLbbmR0AT/zusXAlHA94=';
export const ARCHS = ['x64', 'arm64'];
const FORMAT = 1;
const VERSION_MUSTER = /^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}(-[0-9A-Za-z]{1,20}(\.[0-9A-Za-z]{1,20}){0,4})?$/;

export function nachricht({ version, datei, sha512 }) {
  for (const [name, wert] of Object.entries({ version, datei, sha512 })) {
    if (typeof wert !== 'string' || !wert || /[\r\n]/.test(wert)) throw new Error(`${name} fehlt oder ist ungültig`);
  }
  return Buffer.from(`kleidio-update\n${FORMAT}\n${version}\n${datei}\n${sha512}`, 'utf8');
}

function sha512(datei) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha512');
    fs.createReadStream(datei).on('error', reject).on('data', (d) => h.update(d)).on('end', () => resolve(h.digest('base64')));
  });
}

/** Wirft mit klarer Meldung, wenn etwas nicht passt; sonst Liste der geprüften Dateien. */
export async function pruefen({ ordner, version, schluessel = OEFFENTLICHER_SCHLUESSEL }) {
  if (!VERSION_MUSTER.test(String(version))) throw new Error(`Version ${version} ungültig`);
  const roh = fs.readFileSync(path.join(ordner, 'kleidio-signatur.json'), 'utf8');
  if (roh.length > 16 * 1024) throw new Error('Signatur-Datei zu groß');
  const sig = JSON.parse(roh);
  if (!sig || sig.format !== FORMAT) throw new Error('Signatur-Format unbekannt');
  if (sig.version !== version) throw new Error(`Signatur gilt für ${sig.version}, nicht für ${version}`);
  const key = crypto.createPublicKey({ key: Buffer.from(schluessel, 'base64'), format: 'der', type: 'spki' });
  const geprueft = [];
  for (const arch of ARCHS) {
    const datei = `Kleidio-${version}-linux-${arch}.tar.gz`;
    const e = Array.isArray(sig.dateien) ? sig.dateien.find((x) => x && x.datei === datei) : null;
    if (!e || typeof e.sha512 !== 'string' || typeof e.signatur !== 'string') throw new Error(`${datei} steht nicht in der Signatur`);
    const ist = await sha512(path.join(ordner, datei));
    if (ist !== e.sha512) throw new Error(`Prüfsumme von ${datei} passt nicht zur Signatur`);
    let ok = false;
    try { ok = crypto.verify(null, nachricht({ version, datei, sha512: ist }), key, Buffer.from(e.signatur, 'base64')); } catch { ok = false; }
    if (!ok) throw new Error(`Signatur von ${datei} ungültig`);
    geprueft.push(datei);
  }
  return geprueft;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const [ordner, version] = process.argv.slice(2);
  if (!ordner || !version) { console.error('Aufruf: node server/signatur-pruefen.mjs <ordner> <version>'); process.exit(2); }
  pruefen({ ordner, version }).then(
    (liste) => { for (const d of liste) console.log(`Signatur ok: ${d}`); },
    (f) => { console.error(`Signatur-Prüfung gescheitert: ${f.message}`); process.exit(1); },
  );
}
