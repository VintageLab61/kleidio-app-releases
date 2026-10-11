# Postet eine neue Kleidio-Version in den Discord-Kanal „🆕┃app-updates“ (nur Tester und Team sehen ihn), vom
# Kleidio-Bot (Regel: Kleidio-News nie vom Vintage-Lab-Bot). Läuft als GitHub Action bei jedem veröffentlichten
# Release, auch Vorabversionen (Max, 11.10.2026: „automatisch bitte die Releases“). Jede Version nur einmal: Steht
# ihr Titel schon in den letzten Nachrichten des Kanals, passiert nichts.
#
# Umgebung: KLEIDIO_BOT_TOKEN (Repo-Secret), GITHUB_REPOSITORY, GITHUB_EVENT_NAME, GITHUB_EVENT_PATH, GH_TOKEN,
# TAG (nur beim Start von Hand, leer = neueste Version). Nur ansehen ohne Posten: --vorschau.
import json, os, re, sys, urllib.request, urllib.error

KANAL = '1558496858903552193'  # 🆕┃app-updates auf dem Vintage-Lab-Server
REPO = os.environ.get('GITHUB_REPOSITORY') or 'VintageLab61/kleidio-app-releases'
VORSCHAU = '--vorschau' in sys.argv


def hol(url, kopf=None, methode='GET', daten=None):
    req = urllib.request.Request(url, method=methode, data=json.dumps(daten).encode() if daten is not None else None,
                                 headers={'User-Agent': 'kleidio-app-updates', **(kopf or {})})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read() or b'null')


def release_finden():
    """Das Release aus dem Ereignis, beim Start von Hand das mit TAG oder das zuletzt veröffentlichte."""
    pfad = os.environ.get('GITHUB_EVENT_PATH')
    if os.environ.get('GITHUB_EVENT_NAME') == 'release' and pfad:
        return json.load(open(pfad, encoding='utf-8'))['release']
    gh = {'Accept': 'application/vnd.github+json'}
    if os.environ.get('GH_TOKEN'):
        gh['Authorization'] = 'Bearer ' + os.environ['GH_TOKEN']
    tag = (os.environ.get('TAG') or '').strip()
    if tag:
        return hol(f'https://api.github.com/repos/{REPO}/releases/tags/{tag}', gh)
    # Nach Veröffentlichung sortieren: alle Tags zeigen auf denselben Commit, die Liste von GitHub wäre falsch geordnet.
    alle = [r for r in hol(f'https://api.github.com/repos/{REPO}/releases?per_page=30', gh) if not r.get('draft') and r.get('published_at')]
    return max(alle, key=lambda r: r['published_at'])


def nachricht_bauen(rel):
    """Grüner Container ohne Ping: Titel, Abschnitte „Neu“/„Besser“ fett, Download-Knopf. Wie der erste Post von Hand."""
    tag, titel = rel['tag_name'], rel.get('name') or rel['tag_name']
    exe = next((a['browser_download_url'] for a in rel.get('assets', []) if a['name'].lower().endswith('.exe')), rel['html_url'])
    zeilen = []
    for z in (rel.get('body') or '').replace('\r', '').split('\n'):
        t = z.strip()
        if not t or t == titel or t.startswith('Installieren:'):
            continue
        zeilen.append(f'**{t}**' if re.fullmatch(r'[A-ZÄÖÜ][\wäöüß ]{1,20}', t) and not t.startswith('- ') else t)
    abschnitte = [a.strip() for a in re.split(r'\n(?=\*\*)', '\n'.join(zeilen)) if a.strip()]
    inhalt = [{'type': 10, 'content': f'## {titel}'}]
    for a in abschnitte:
        inhalt.append({'type': 14, 'divider': True, 'spacing': 1})
        inhalt.append({'type': 10, 'content': a[:1800]})
    inhalt += [{'type': 14, 'divider': True, 'spacing': 1},
               {'type': 10, 'content': '-# Schon installiert? Die App aktualisiert sich von selbst. Neu dabei: Datei laden und doppelklicken.'},
               {'type': 1, 'components': [{'type': 2, 'style': 5, 'label': 'Download für Windows', 'url': exe},
                                          {'type': 2, 'style': 5, 'label': 'Alle Versionen', 'url': f'https://github.com/{REPO}/releases'}]}]
    return tag, titel, {'flags': 1 << 15, 'components': [{'type': 17, 'accent_color': 0x25c281, 'components': inhalt}],
                        'allowed_mentions': {'parse': []}}


def texte_von(komponenten):
    """Alle Texte (Typ 10) aus verschachtelten Komponenten."""
    for k in komponenten or []:
        if k.get('type') == 10 and isinstance(k.get('content'), str):
            yield k['content']
        yield from texte_von(k.get('components'))


def schon_gepostet(titel, nachrichten):
    """Steht genau die Überschrift dieser Version schon in einer der letzten Nachrichten? Genau, nicht als Anfang:
    „Kleidio 0.3.0“ ist nicht schon gepostet, nur weil „Kleidio 0.3.0-beta.1“ im Kanal steht."""
    kopf = f'## {titel}'
    for n in nachrichten or []:
        zeilen = [z.strip() for t in texte_von(n.get('components')) for z in t.split('\n')] + [z.strip() for z in (n.get('content') or '').split('\n')]
        if kopf in zeilen:
            return True
    return False


def main():
    rel = release_finden()
    if rel.get('draft'):
        print('Entwurf, nichts gepostet.')
        return
    tag, titel, nachricht = nachricht_bauen(rel)
    texte = [k['content'] for k in nachricht['components'][0]['components'] if k['type'] == 10]
    if sum(len(t) for t in texte) > 4000:
        sys.exit(f'{tag}: Text zu lang für Discord ({sum(len(t) for t in texte)} von 4000 Zeichen).')
    if VORSCHAU:
        print('\n\n'.join(texte))
        return
    token = os.environ.get('KLEIDIO_BOT_TOKEN', '').strip()
    if not token:
        sys.exit('KLEIDIO_BOT_TOKEN fehlt (Repo-Secret).')
    dc = {'Authorization': 'Bot ' + token, 'Content-Type': 'application/json', 'User-Agent': 'DiscordBot (kleidio, 1)'}
    try:
        if schon_gepostet(titel, hol(f'https://discord.com/api/v10/channels/{KANAL}/messages?limit=25', dc)):
            print(f'{titel} steht schon im Kanal, nichts gepostet.')
            return
        antwort = hol(f'https://discord.com/api/v10/channels/{KANAL}/messages', dc, 'POST', nachricht)
    except urllib.error.HTTPError as e:
        sys.exit(f'Discord: HTTP {e.code} {e.read()[:300]!r}')
    print(f'Gepostet: {titel} (Nachricht {antwort["id"]})')


if __name__ == '__main__':
    main()
