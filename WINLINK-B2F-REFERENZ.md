# Winlink B2F – Protokoll-Referenz & Pat-Quellcode-Analyse

**Zweck:** Grundlage für die Machbarkeitsabschätzung «Stufe 1» – ein nativer Swift-Winlink-Client
(Telnet/CMS) für macOS, potenziell als Modul für Ham-Tools.
**Stand:** Juli 2026 · Erstellt für Chris HB9HJI

---

## 1. Die Protokoll-Schichten im Überblick

Winlink verwendet – analog zu TCP/IP – geschichtete Protokolle:

```
┌─────────────────────────────────────────────┐
│  B2-Nachrichtenformat (Header + Body + Files)│  ← Nachricht selbst
├─────────────────────────────────────────────┤
│  LZHUF-Kompression + CRC                     │  ← Kompressionsschicht
├─────────────────────────────────────────────┤
│  FBB/B2F Forwarding-Protokoll                │  ← Session: Login, Proposals, Transfer
├─────────────────────────────────────────────┤
│  Transport: Telnet (TCP) | VARA | ARDOP |    │  ← austauschbar!
│  AX.25 Packet | Pactor                       │
└─────────────────────────────────────────────┘
```

Wichtig für Stufe 1: **Der Transport ist eine simple `net.Conn`-Abstraktion.** In wl2k-go läuft
die komplette B2F-Session über ein generisches Stream-Interface – ob dahinter TCP (Telnet),
VARA oder ARDOP steckt, ist der Session-Logik egal. In Swift entspricht das einem Protokoll
à la `WinlinkTransport` (read/write/close), das man zuerst nur mit `Network.framework`
(NWConnection, TCP) implementiert. VARA/ARDOP kommen später als weitere TCP-Implementierungen
dazu, da beide Modems TCP-Command/Data-Ports anbieten.

### Telnet-Zugang zum CMS (die Konstanten)

Aus `wl2k-go/transport/telnet/dial.go`:

| Parameter | Wert |
|---|---|
| Server | `server.winlink.org:8772` |
| Target Call | `wl2k` |
| Telnet-Passwort (fix, systemweit) | `CMSTelnet` |
| Login | Callsign, danach Secure-Login-Challenge (;PQ/;PR) mit dem persönlichen Winlink-Passwort |

Der Telnet-Handshake vor der FBB-Session ist trivial: Der Server fragt `Callsign :` und
`Password :` (hier kommt `CMSTelnet` hin, nicht dein Account-Passwort), danach beginnt
die eigentliche B2F-Session.

---

## 2. Der B2F-Session-Ablauf (Handshake)

Eine reale CMS-Session sieht so aus (`<` = vom CMS, `>` = vom Client, Zeilenende ist CR):

```
<  Callsign :
>  HB9HJI
<  Password :
>  CMSTelnet
<  [WL2K-5.0-B2FWIHJM$]          ← SID des Servers
<  ;PQ: 34876690                  ← Passwort-Challenge
<  CMS via ...
>  ;FW: HB9HJI                    ← Für welche Calls Mail abgeholt wird
>  [HamTools-1.0-B2FHM$]          ← SID des Clients
>  ;PR: 90577715                  ← Challenge-Response
>  FF                             ← «Ich habe nichts, was hast du?»
<  ;PM: HB9HJI ABC123XYZ 274 ...  ← Pending-Message-Info
<  FC EM ABC123XYZ 354 274 0      ← Proposal: Nachricht ABC123XYZ
<  F> 4C                          ← Ende Proposal-Block + Checksumme
>  FS Y                           ← Annehmen
<  [komprimierter Binärblock]     ← Die Nachricht selbst
>  FF                             ← Weiter / nichts mehr
<  FQ                             ← Session-Ende
```

### Die SID (System-ID)

Format: `[Name-Version-Features$]`, z. B. `[WL2K-5.0-B2FWIHJM$]`. Die Feature-Buchstaben
deklarieren die Fähigkeiten. wl2k-go nutzt als eigene SID: `B2` (FBB compressed v2 = B2F,
zwingend), `F` (FBB basic), `H` (Hierarchical location), `M` (MID) und `$` (BID, muss das
letzte Zeichen sein). Der Client prüft beim Gegenüber nur, ob `B2` vorhanden ist.

### Secure Login (;PQ / ;PR) – komplett dokumentiert

Das ist der Teil, der auf den ersten Blick «geheim» wirkt, aber längst offen implementiert
ist (paclink-unix → wl2k-go, `fbb/secure.go`, nur 41 Zeilen):

```
payload  = challenge + passwort + festes_64-Byte-Salt
sum      = MD5(payload)
pr       = (sum[3] & 0x3f) << 24 | sum[2] << 16 | sum[1] << 8 | sum[0]
response = letzte 8 Stellen von "%08d" % pr
```

Das 64-Byte-Salt steht hartkodiert in `secure.go` (ursprünglich aus paclink-unix). In Swift
ist das mit `CryptoKit` (`Insecure.MD5`) ein Nachmittag inklusive Unit-Tests – die
Testvektoren kann man direkt aus `secure_test.go` übernehmen.

### Proposals (FA/FB/FC/FD, FS, FF, FQ)

- **FC** = Compressed-v2-Proposal (B2F, das ist der Normalfall): `FC EM <MID> <unkomprimierte Grösse> <komprimierte Grösse> 0`
- **F>** beendet einen Proposal-Block (mit einfacher Checksumme)
- **FS** = Antwort auf Proposals, ein Zeichen pro Proposal: `+`/`Y` (annehmen), `-`/`N` (ablehnen), `=` (später), plus Offset-Varianten für **Resume abgebrochener Transfers**
- **FF** = «nichts (mehr) zu senden», **FQ** = Session-Ende
- Bis zu 5 Proposals pro Block (wl2k-go: `MaxBlockSize = 5`)

---

## 3. Das B2-Nachrichtenformat

Eine Winlink-Nachricht ist RFC822-ähnlich, aber eigenständig. Header (aus `fbb/header.go`):

```
Mid: ABC123XYZ12
Date: 2026/07/03 14:30
Type: Private
From: HB9HJI
To: HB9HWG
Subject: Test von Ham-Tools
Mbo: HB9HJI
Body: 123                ← Länge des Bodys in Bytes
File: 4567 bild.jpg      ← pro Attachment eine File-Zeile (Grösse + Name)

<Body, ISO-8859-1>
<Attachment-Daten>
```

Wichtige Eigenheiten:
- **Charset ist faktisch ISO-8859-1** – für Umlaute (ü, ö, ä) relevant, aber kein ß-Problem für dich ;)
- **MID** = 12-stellige eindeutige Message-ID (Basis-36-artig, siehe `fbb/mid.go`, 24 Zeilen)
- Attachments sind roh angehängt, Grössen stehen im Header

### Kompression: LZHUF + CRC

Vor der Übertragung wird die komplette Nachricht (Header+Body+Files) **LZHUF-komprimiert**
(LZ77 + adaptive Huffman-Codierung, historisch aus FBB/JNOS). Dem komprimierten Bild wird
eine 2-Byte-CRC-Prüfsumme vorangestellt, dann wird es in Blöcke zerlegt (Blocktypen mit
Längenbyte, Endblock mit Checksumme). Referenzen:

- Go-Port: `wl2k-go/lzhuf/` (~940 Zeilen inkl. Reader/Writer/CRC, **exzellente Testabdeckung**
  in `lzhuf_test.go` mit 482 Zeilen → fertige Testvektoren für den Swift-Port!)
- Offizieller VB.NET-Quellcode: github.com/ARSFI/Winlink-Compression
- Neuere Server unterstützen zusätzlich **Gzip** (Proposal-Typ `FD` statt `FC`) – das wäre
  in Swift gratis (`Compression`-Framework), aber LZHUF bleibt für maximale Kompatibilität
  Pflicht (Fallback, wenn die Gegenstelle kein `D`-Feature in der SID hat).

---

## 4. Pat / wl2k-go: Quellcode-Landkarte

Pat (der Client) und wl2k-go (die Protokoll-Library) sind sauber getrennt – genau die
Architektur, die auch für Swift Sinn ergibt.

### wl2k-go – die Library (das, was du portierst)

| Paket | Zeilen (ohne Tests) | Inhalt | Swift-Relevanz Stufe 1 |
|---|---|---|---|
| `fbb/` | ~1'850 | Session, Handshake, Proposals, B2-Message, MID, Secure Login | **JA – Kernstück** |
| `lzhuf/` | ~940 | LZHUF-Kompression, CRC, Bit-Reader | **JA – Kernstück** |
| `transport/telnet/` | ~180 | CMS-Telnet-Verbindung | **JA – trivial** |
| `mailbox/` | ~1 Datei | Verzeichnisbasierte Mailbox (Dateien pro Nachricht) | Ja, aber du machst es eh anders (Core Data/SQLite) |
| `transport/ardop/` | ~1'900 | ARDOP-TNC über TCP | Stufe 2 |
| `transport/ax25/` | ~1'500 | Packet (AGWPE, Linux-Native, KISS) | Stufe 2 |
| `rigcontrol/hamlib/` | ~800 | rigctld-Client | Stufe 2 (kennst du vom IC-705) |

**Kern für Stufe 1: rund 3'000 Zeilen Go**, davon fast die Hälfte LZHUF. Die wichtigsten
Dateien zum Studieren, in dieser Reihenfolge:

1. `fbb/wl2k.go` (428 Z.) – `Session.Exchange()`, die Hauptschleife
2. `fbb/handshake.go` (256 Z.) – SID, ;PQ/;PR, ;FW, Feature-Negotiation
3. `fbb/proposal.go` (236 Z.) – FC/FS/FF/FQ, Blockbildung
4. `fbb/message.go` (599 Z.) – B2-Format lesen/schreiben
5. `fbb/secure.go` (41 Z.) – Challenge-Response
6. `lzhuf/` – zuletzt, weil in sich geschlossen und gut getestet

### Pat – die App obendrauf (Inspiration, nicht Portierungsziel)

- `app/` – Verbindungslogik, Exchange-Orchestrierung, Config, Event-Log
- `cli/` – Kommandozeilen-Interface (connect, read, composer, position, …)
- `web/` + `api/` – Web-GUI mit WebSocket-Hub
- `app/rmslist.go` – **RMS-Gateway-Liste von der Winlink-API holen** (welche Gateways auf
  welcher QRG) – für Stufe 2 Gold wert, die API dahinter ist eine simple HTTP-Schnittstelle
- `app/winlink_api.go` / `api/winlink_account.go` – Account-Funktionen über die Winlink-HTTP-API

Lizenz: MIT – Portieren nach Swift ist damit sauber möglich (Attribution genügt).

---

## 5. Portierungsplan Swift (Vorschlag «WinlinkKit»)

```
WinlinkKit (Swift Package, keine UI)
├── Transport/
│   ├── WinlinkTransport.swift       ← Protokoll (read/write/close)
│   └── TelnetTransport.swift        ← NWConnection, Handshake bis SID
├── FBB/
│   ├── SID.swift                    ← parsen/erzeugen, Feature-Flags
│   ├── SecureLogin.swift            ← MD5-Challenge (CryptoKit)
│   ├── Proposal.swift               ← FC/FS/FF/FQ
│   ├── Session.swift                ← Exchange-Statemachine (async/await!)
│   └── B2Message.swift              ← Header/Body/Files, ISO-8859-1
├── LZHUF/
│   ├── LZHUF.swift                  ← Encoder/Decoder
│   └── CRC16.swift
└── Tests/                           ← Testvektoren 1:1 aus wl2k-go übernehmen
```

**Aufwandsschätzung Stufe 1** (Claude Code auf dem DEV-Mac, dein Tempo):

| Baustein | Aufwand | Risiko |
|---|---|---|
| TelnetTransport + SID + SecureLogin | 1–2 Sessions | tief – alles dokumentiert |
| B2Message (Format lesen/schreiben) | 1–2 Sessions | tief |
| LZHUF-Port | 2–3 Sessions | **mittel** – Bit-Genauigkeit! Testvektoren aus lzhuf_test.go sind der Schlüssel |
| Session-Statemachine (Exchange) | 2–3 Sessions | mittel – viele Randfälle (Resume, Defer, Reject) |
| Integration/E2E-Test gegen echtes CMS | 1 Session | tief – Telnet-Test kostet nichts, kein Funk nötig |

Realistisch: **ein funktionierender Telnet-Send/Receive in 2–3 Wochen Feierabend-Tempo.**
Der grosse Vorteil: Man kann jederzeit gegen das echte CMS per Telnet testen, ohne Funk,
ohne Modem – schneller Feedback-Loop, ideal für Claude Code mit E2E-Tests.

**Debug-Tipp:** Pat lokal laufen lassen und den Telnet-Traffic mit `tcpdump`/Wireshark
mitschneiden → Referenz-Sessions als Fixtures für die Swift-Tests.

---

## 6. Stufe 2 (Ausblick): Funkanbindung

- **VARA HF/FM:** TCP-Command-Port (Default 8300) + Data-Port (8301). Textkommandos
  (`MYCALL`, `LISTEN`, `CONNECT`, …), Daten roh über den Data-Port. VARA läuft unter
  Crossover/Wine oder auf einem separaten Rechner – WinlinkKit spricht nur TCP.
- **ARDOP:** analog, Command-Port 8515/Data 8516; native Builds (ardopcf) laufen direkt
  auf macOS. wl2k-go/transport/ardop ist die Referenz (~1'900 Zeilen).
- **Packet:** Direwolf nativ auf macOS, Anbindung über AGWPE-TCP oder KISS.
- **PTT/Rig:** rigctld-Client (simples Text-über-TCP-Protokoll, `T 1`/`T 0` für PTT).
- **RMS-Liste:** Winlink-HTTP-API (siehe `pat/app/rmslist.go`) für Gateway-Suche nach
  Band/Distanz ab JN47PN.

---

## 7. Quellen

- Offizielle B2F-Spezifikation: https://winlink.org/B2F
- Winlink Data Flow & Packaging (PDF): https://winlink.org/sites/default/files/downloads/winlink_data_flow_and_data_packaging.pdf
- LZH-Kompression (offiziell, VB.NET): https://github.com/ARSFI/Winlink-Compression
- wl2k-go (Go-Referenzimplementierung, MIT): https://github.com/la5nta/wl2k-go
- Pat (Client): https://github.com/la5nta/pat · https://getpat.io
- FBB-Original-Protokoll: http://www.f6fbb.org/
- B2F-Protokoll-Wiki (F4HOF): https://f4hof.net/doku.php/b2f:start
- Beispiel-Session dokumentiert (AC0KQ): https://www.rmham.org/wp-content/uploads/2022/03/3_AC0KQ-NTSGW.pdf

*73 – erstellt mit Claude für das WinlinkKit-Projekt*
