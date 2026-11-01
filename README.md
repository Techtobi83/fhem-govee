# 98_GOVEE – Govee-Lampen direkt in FHEM

FHEM-Modul für Govee-Lampen und LED-Streifen: Steuerung und Status **lokal im LAN**, Szenen über die
Govee-Cloud. Ohne Home Assistant, ohne MQTT und ohne Bridge-Container. Die Auswahl in FHEM zeigt dieselben Szenen wie die Govee-App, passend zum
jeweiligen Lampenmodell.

## Funktionen

- Schalten, Helligkeit, Farbe und Farbtemperatur über die lokale LAN-Schnittstelle
- **Alle App-Szenen** je Modell als Auswahlliste, mit API-Key über die Cloud gestartet, ohne Key per LAN
- DIY-Szenen über die Govee-Cloud, gleiche Namen werden durchnummeriert
- Status per LAN-Abfrage: Änderungen aus der App erscheinen nach spätestens `lanInterval` Sekunden
- Cloud als Rückfall für Lampen, die im LAN nicht antworten
- Automatische Suche, geänderte IP-Adressen werden von selbst übernommen
- Events nur bei echten Änderungen, die Abfragen belasten das Event-Log nicht
- Szenenkopie im Log-Verzeichnis, damit Szenen auch ohne Internet laufen
- API-Key verschleiert im FHEM-Schlüsselspeicher, nicht in der `fhem.cfg`
- Ausführliche FHEM-Hilfe auf Deutsch und Englisch (`help GOVEE`)

## Grenzen

- Govee-Lampen melden Änderungen im LAN nicht von sich aus. Das Modul fragt deshalb regelmäßig ab.
- Das Reading `effect` zeigt die zuletzt von FHEM gestartete Szene. Lampen melden die laufende
  Szene nicht.
- Die Szenenbibliothek und die LAN-Szenenpakete sind nicht von Govee dokumentiert und können sich ändern.
- LAN-Szenen nimmt nicht jede Lampe zuverlässig an: Ein H61D5 kehrte danach zur letzten DIY-Szene zurück.
  Mit API-Key laufen Szenen deshalb über die Cloud. `attr <Lampe> sceneRoute lan` erzwingt das LAN.

## Voraussetzungen

- **LAN-Steuerung** je Lampe in der Govee-Home-App aktiviert.
- FHEM im selben Netz wie die Lampen. In Docker ist dafür Host-Netzwerk nötig.
- UDP-Port 4002 auf dem FHEM-Rechner frei.
- FHEM mit dem Perl-Modul `JSON` (Debian: `libjson-perl`).
- Empfohlen ein **Govee-API-Key** für Szenen, DIY-Szenen und den Cloud-Rückfall:
  Govee-Home-App, Profil, Einstellungen (Zahnrad), *Apply for API Key*.

## Installation

**Über das FHEM-Update** (empfohlen, so kommen auch spätere Versionen automatisch):

```
update add https://raw.githubusercontent.com/Techtobi83/fhem-govee/main/controls_govee.txt
update all https://raw.githubusercontent.com/Techtobi83/fhem-govee/main/controls_govee.txt
shutdown restart
```

**Oder von Hand:** `FHEM/98_GOVEE.pm` nach `/opt/fhem/FHEM/` kopieren (Besitzer `fhem`) und FHEM neu starten
oder `reload 98_GOVEE` eingeben.

## Einrichtung

```
define GoveeBridge GOVEE BRIDGE
set GoveeBridge scan
```

Für jede gefundene Lampe entsteht ein Gerät `GOVEE_<Modell>_<ID>` im Raum der Bridge. Mit API-Key:

```
set GoveeBridge apiKey <Schlüssel>
```

## Bedienung

```
set Lampe on
set Lampe brightness 40
set Lampe rgb FF8800
set Lampe ct 4000
set Lampe effect Sunset#Glow
set Lampe diy_scene MeineSzene
```

## Szenen in FTUI3

Das Reading `sceneList` enthält die wählbaren Szenen und füllt direkt eine Auswahlliste:

```html
<ftui-dropdown placeholder="Szene wählen" delimiter=","
  [list]="Lampe:sceneList" [value]="Lampe:effect"
  (value)="set Lampe effect $value"></ftui-dropdown>
```

Mit dem Attribut `sceneFilter` kürzt du lange Listen, `^(?!Shape:)` blendet zum Beispiel die Kategorie Shape aus.

Alle Befehle, Attribute und Readings stehen in `help GOVEE`.

## Dank

Paketaufbau der Szenen und die Beschreibung der Schnittstellen nach
[govee2mqtt](https://github.com/wez/govee2mqtt) von Wez Furlong (MIT-Lizenz).

Govee ist eine Marke der Shenzhen Intellirocks Tech. Co., Ltd. Dieses Modul steht in keiner
Verbindung zu Govee.

## Lizenz

GPL-2.0-or-later, siehe [LICENSE](LICENSE).
