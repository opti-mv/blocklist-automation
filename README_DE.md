# blocklist-automation

Ziel: One-Liner-Installation, die die Blocklist auf einem oder mehreren Linux-Hosts einrichtet.

## One-Liner-Installation

Als root ausfuehren (oder mit sudo):

```bash
curl -fsSL https://raw.githubusercontent.com/opti-mv/blocklist-automation/main/install.sh | sudo bash
```

## Was es macht

- Installiert benoetigte Pakete (Debian/Ubuntu via apt; best-effort)
- Erstellt `/opt/blocklist`
- Laedt Skripte + `blocklists.txt` + optionale `allowlist.txt` aus diesem Repo herunter
- Erstellt `/var/log/blocklist` mit sicheren Berechtigungen
- Richtet einen Scheduler ein:
  - systemd-Timer, wenn verfuegbar
  - sonst Cron-Fallback
- Fuehrt waehrend der Installation sofort einen initialen Lauf aus (wartet nicht auf das erste Timer/Cron-Zeitfenster).

- Fuehrt alle Skriptausgaben in einer Logdatei zusammen: `/var/log/blocklist/blocklist.log`, und konfiguriert
  `logrotate` fuer Rotation/Komprimierung (verwaltet durch `install.sh`). Der eingerichtete Scheduler
  (systemd-Timer oder Cron-Fallback) fuehrt beide Skripte aus und schreibt die Ausgabe in diese Datei.

## Dateien

- `blocklist/blocklists.txt` - Liste der Quell-URLs
- `blocklist/allowlist.txt` - optionale IP/CIDR-Ausnahmen, die niemals geblockt werden sollen
- `blocklist/download_and_create_ipsets.sh` - laedt Listen herunter und aktualisiert ipsets
- `blocklist/set-ipsets2drop.sh` - stellt sicher, dass iptables/ip6tables-Regeln existieren
- `install.sh` - Installer fuer den One-Liner
- `uninstall.sh` - entfernt verwalteten Scheduler, Regeln/Sets und verwaltete Dateien

Logging und Rotation
- Der Installer erstellt `/var/log/blocklist` und konfiguriert `/etc/logrotate.d/blocklist-automation`.
- Alle Skripte schreiben standardmaessig nach `/var/log/blocklist/blocklist.log`. Fuer einen einzelnen Lauf kann
  `BLOCKLIST_LOGFILE` vor dem Ausfuehren der Skripte gesetzt werden.

nftables-Unterstuetzung
- Die Skripte erkennen automatisch den Backend-Pfad in folgender Prioritaet:
  - `iptables-nft` + `ipset` (bevorzugt)
  - natives `nftables`
  - klassisches `iptables` + `ipset` nur als letzter Fallback
  - Zum Erzwingen: `USE_NFT=1` (nft-Modus erzwingen) oder `USE_NFT=0` (ipset-Modus erzwingen) in der
    Umgebung vor dem Skriptstart setzen.
- Der Installer versucht zuerst `iptables-nft` + `ipset`; wenn das nicht verfuegbar/installierbar ist, wird `nft` genutzt, und nur als letzter Schritt auf klassisches `iptables` + `ipset` zurueckgefallen.
- Zur Kollisionsvermeidung bekommen Blocklist-Sets standardmaessig ein Praefix (`BLOCKLIST_SET_PREFIX=blklst_`).
- Im nft-Modus werden Sets/Regeln in `inet blocklist_auto` (`BLOCKLIST_NFT_TABLE`) und Chain
  `input_blocklist` (`BLOCKLIST_NFT_CHAIN`) verwaltet.

Allowlist-Unterstuetzung
- Vertraute IPs/CIDRs in `/opt/blocklist/allowlist.txt` eintragen (oder `BLOCKLIST_ALLOWLIST_FILE` setzen).
- Passende Eintraege werden vor dem Set-Update aus allen heruntergeladenen Blocklists entfernt.

Hash-basierte Updates
- Das Download-Skript speichert pro Set einen SHA-256-Hash in `/var/lib/blocklist` (uebersteuerbar mit `BLOCKLIST_STATE_DIR`).
- Sets werden nur dann aktualisiert, wenn sich die final normalisierten Eintraege wirklich geaendert haben.

Cron-Verhalten
- Wenn systemd nicht verfuegbar ist, bleiben vorhandene root-Crontab-Eintraege erhalten, und es wird nur ein verwalteter Block hinzugefuegt/aktualisiert.
- Der Cron-Fallback laeuft zwei Mal taeglich (`*/12`) zu einer host-randomisierten Minute; mit `CRON_SCHEDULE` ueberschreibbar.
- Mit systemd laeuft der Timer um 00:00 und 12:00 mit randomisierter Verzoegerung (`RandomizedDelaySec=30m`).

## Hinweise / Annahmen

- Ausgelegt fuer Hosts mit entweder `nftables` oder `ipset`+`iptables`/`ip6tables`.
- Quelle der Blocklist-Dateien: https://ipv64.net/v64_blocklists
  - Hinweis: Die Quelle bietet zusaetzliche Blocklists und GeoBlocklists. Wenn du sie nutzen willst, fuege die entsprechenden URLs in `blocklist/blocklists.txt` ein (und starte den Installer erneut oder warte auf den naechsten geplanten Lauf).
- Es werden Root-Rechte benoetigt, um Firewall-Sets/-Regeln zu verwalten.

Deinstallation
- Ausfuehren: `sudo /opt/blocklist/uninstall.sh`
- Optional: `REMOVE_LOGS=1 sudo /opt/blocklist/uninstall.sh`, um zusaetzlich `/var/log/blocklist` zu entfernen.
