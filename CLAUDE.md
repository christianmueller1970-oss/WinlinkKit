# CLAUDE.md – WinlinkKit

**Projekt:** WinlinkKit – ein natives Swift-Package, das das Winlink-B2F-Protokoll implementiert.
**Owner:** Chris, HB9HJI (JN47PN, Amriswil TG) · Präsident HB9AF
**Umgebung:** DEV-Mac (MacBook Air, Apple Silicon), Xcode aktuell, Claude Code
**Sprache im Projekt:** Kommunikation auf Deutsch (Schweizer Rechtschreibung, kein «ß» – immer «ss»).
Code, Kommentare und Commit-Messages auf Englisch.

---

## 1. Was wir bauen (und warum)

WinlinkKit ist die Protokoll-Bibliothek für einen nativen macOS-Winlink-Client. Langfristiges Ziel:
Integration als Winlink-Modul in **Ham-Tools** (Chris' native macOS-Logging-App). WinlinkKit selbst
enthält **keine UI** – nur Protokoll, Transport und Mailbox-Abstraktion.

**Stufe 1 (dieses Repo, Meilensteine M0–M4):** Winlink-Mail senden und empfangen über
**Telnet/TCP** zum CMS (`server.winlink.org:8772`) – ohne Funk, ohne Modem.

**Stufe 2 (später):** Transport-Implementierungen für VARA (TCP 8300/8301), ARDOP (TCP 8515/8516)
und AX.25/AGWPE (Direwolf), plus rigctld-PTT. Die Architektur muss das von Anfang an
ermöglichen (Transport-Abstraktion!), implementiert wird es aber erst nach Abschluss von Stufe 1.

**Referenzimplementierung:** [wl2k-go](https://github.com/la5nta/wl2k-go) (Go, MIT-Lizenz) –
wir portieren die Kernlogik nach Swift. Das Repo lokal klonen nach `./reference/wl2k-go`
(steht in `.gitignore`), damit du beim Portieren direkt in den Go-Code schauen kannst.
Zusätzliche Doku: `WINLINK-B2F-REFERENZ.md` im Repo-Root (Protokoll-Überblick, Session-Beispiel).

**Attribution:** wl2k-go ist MIT-lizenziert (Martin Hebnes Pedersen LA5NTA). WinlinkKit wird
ebenfalls MIT. LICENSE-Datei muss den Hinweis «Portions ported from wl2k-go» enthalten.

---

## 2. Architektur & Package-Layout

Swift Package (SPM), Swift 6, Strict Concurrency. Kern-APIs mit `async/await`.
Keine externen Dependencies für den Kern – nur Foundation, Network.framework, CryptoKit.

```
WinlinkKit/
├── CLAUDE.md                        ← dieses Dokument
├── WINLINK-B2F-REFERENZ.md          ← Protokoll-Referenz
├── Package.swift
├── Sources/WinlinkKit/
│   ├── Transport/
│   │   ├── WinlinkTransport.swift   ← protocol: read/write/close (async)
│   │   └── TelnetTransport.swift    ← NWConnection; Callsign/Password-Prompt bis Session-Start
│   ├── FBB/
│   │   ├── SID.swift                ← [Name-Version-Features$] parsen/erzeugen
│   │   ├── SecureLogin.swift        ← ;PQ/;PR MD5-Challenge (CryptoKit, Insecure.MD5)
│   │   ├── MID.swift                ← 12-Zeichen Message-ID (MD5 → Base32)
│   │   ├── Proposal.swift           ← FC/FS/FF/FQ, Blockbildung (max 5), Checksumme
│   │   ├── B2Message.swift          ← Header/Body/Files, ISO-8859-1
│   │   └── B2FSession.swift         ← Exchange-Statemachine
│   ├── LZHUF/
│   │   ├── LZHUF.swift              ← Encoder/Decoder (LZ77 + adaptive Huffman)
│   │   ├── BitReader.swift
│   │   └── CRC16.swift
│   └── Mailbox/
│       └── MailboxHandler.swift     ← protocol; einfache Dir-Implementierung für Tests
├── Tests/WinlinkKitTests/
│   ├── Fixtures/                    ← Golden Files aus wl2k-go/lzhuf/testdata (siehe §5)
│   ├── LZHUFTests.swift
│   ├── SecureLoginTests.swift
│   ├── SIDTests.swift
│   ├── B2MessageTests.swift
│   └── SessionTests.swift           ← gescriptete Sessions gegen Mock-Transport
└── reference/wl2k-go/               ← geklont, gitignored
```

**Design-Regeln:**
- `B2FSession` kennt nur `WinlinkTransport` – niemals konkrete Netzwerk-Typen.
- Alles synchron Testbare (LZHUF, SID, SecureLogin, B2Message, Proposal-Parsing) ist pure
  Logik ohne I/O → direkt unit-testbar ohne Mocks.
- Session-Statemachine als explizites `enum State` mit dokumentierten Übergängen –
  kein impliziter Zustand in verstreuten Bools.
- Fehler als typisierte `WinlinkError`-Enums, nie `fatalError` im Protokollpfad.
- Öffentliche API minimal halten; alles andere `internal`.

---

## 3. Meilensteine

Jeder Meilenstein endet mit: grüne Tests, kurzes Fazit an Chris, **Freigabe abwarten** vor dem
nächsten Meilenstein.

### M0 – Gerüst (½ Session)
- SPM-Package anlegen, Verzeichnisstruktur, `.gitignore` (inkl. `reference/`), LICENSE (MIT + Attribution)
- wl2k-go nach `reference/` klonen, Testdaten nach `Tests/Fixtures/` kopieren
- CI-fähig: `swift build && swift test` läuft (auch wenn noch fast leer)

### M1 – Kryptobausteine & Parser (1–2 Sessions)
- `SecureLogin.swift`: Port von `fbb/secure.go` (41 Zeilen). Salt 1:1 übernehmen.
  Testvektoren aus `fbb/secure_test.go`.
- `MID.swift`: Port von `fbb/mid.go` (MD5 über "\(timestamp)-\(callsign)" → Base32, 12 Zeichen).
- `SID.swift`: Parsen + Erzeugen. Eigene SID: `[WinlinkKit-<version>-B2FHM$]`.
  Prüfung: Gegenstelle MUSS `B2` haben, sonst Abbruch mit klarem Fehler.
- Tests aus `fbb/handshake_test.go` und `fbb/secure_test.go` portieren.

### M2 – LZHUF (2–3 Sessions, das anspruchsvollste Stück)
- Port von `lzhuf/lzhuf.go`, `bit_reader.go`, `crc.go`, `reader.go`, `writer.go` (~940 Zeilen Go).
- **Bit-Genauigkeit ist alles.** Vorgehen: zuerst Decoder (gegen die `.lzh`-Golden-Files),
  dann Encoder (Roundtrip + byteweiser Vergleich mit den Golden Files).
- Golden Files: `e.txt`, `pi.txt`, `gettysburg.txt`, `Mark.Twain-Tom.Sawyer.txt`,
  `LPE5NXDVLVSQ.b2f` – jeweils mit `.lzh`-Pendant. Der `.b2f`-Fixture ist eine **echte
  Winlink-Nachricht** – perfekt auch für M3.
- B2-Framing beachten: 2-Byte-CRC vor dem komprimierten Bild, Blockstruktur mit Endblock
  (siehe `NewB2Writer`/`NewB2Reader` in Go und «Winlink Data Flow»-PDF).
- Achtung bei Go→Swift: Go-Ints sind 64-bit signed, das Original-LZHUF arbeitet mit
  C-artigen Indizes – in Swift konsequent `Int` intern, `UInt8`/`UInt16` an den Rändern,
  Overflow-Verhalten explizit machen (kein `&+` ohne Kommentar).

### M3 – B2-Nachrichtenformat (1–2 Sessions)
- Port von `fbb/message.go` (599 Z.), `header.go`, `message_body.go`.
- Charset: Default ISO-8859-1 (`Content-Type`-Param `charset` beachten,
  siehe `SetBodyWithCharset` in Go). Umlaute in Tests abdecken (ü/ö/ä – wir sind Schweizer,
  ß brauchen wir nicht, testen es aber trotzdem als Latin-1-Zeichen).
- Header: Mid, Date (`yyyy/MM/dd HH:mm`, UTC), Type, From, To, Cc, Subject, Mbo, Body, File.
- Attachments (File-Zeilen) inkl. Grössenvalidierung.
- Test: `LPE5NXDVLVSQ.b2f` dekomprimieren → parsen → serialisieren → byteidentisch.

### M4 – Session-Statemachine & Telnet (2–3 Sessions)
- `Proposal.swift`: Port von `fbb/proposal.go` (FC/FS/FF/FQ, `F>`-Checksumme, max 5 pro Block,
  Antworten `+`/`-`/`=`, Resume-Offsets zunächst nur lesen/ablehnen, TODO für später).
- `B2FSession`: Port von `fbb/wl2k.go` + `handshake.go`. Ablauf siehe Referenz-Doku §2.
- `TelnetTransport`: `NWConnection` zu `server.winlink.org:8772`; Prompts `Callsign :` /
  `Password :` (Antwort: Callsign bzw. fix `CMSTelnet`), danach übernimmt die Session.
  Timeout 30 s, Retry (bis 4×) wie in Go.
- `SessionTests` mit Mock-Transport: gescriptete Byte-Sequenzen (die Beispiel-Session aus
  der Referenz-Doku als Fixture).
- **E2E-Test (manuell, nicht in CI):** kleines CLI-Target `winlinkkit-cli` mit
  `send`/`fetch` gegen das echte CMS. Credentials via Umgebungsvariablen
  (`WL_CALLSIGN`, `WL_PASSWORD`) – **niemals** ins Repo, niemals in Logs ausgeben.
  Erster Live-Test: Mail an HB9HJI@winlink.org senden, dann abholen.

### M5 – Politur & Übergabe-Doku (1 Session)
- README mit API-Beispiel, DocC-Kommentare auf der öffentlichen API.
- `INTEGRATION.md`: Wie Ham-Tools das Package einbindet (SPM-Dependency, API-Skizze,
  Threading-Modell, Vorschlag für Mailbox-Persistenz in Ham-Tools statt Dir-Handler).
- Backlog-Datei für Stufe 2 (VARA/ARDOP/AX.25, rigctld, RMS-Liste via Winlink-HTTP-API,
  Gzip-Proposals `FD`, Resume-Offsets, ;FW-Aux-Calls).

---

## 4. Portierungs-Konventionen Go → Swift

| Go (wl2k-go) | Swift (WinlinkKit) |
|---|---|
| `net.Conn` | `protocol WinlinkTransport` (async read/write/close) |
| `io.Reader`/`io.Writer` über Streams | `Data`-basierte Funktionen wo möglich; Streaming nur wo nötig (LZHUF-Reader/Writer) |
| Fehler als `error`-Rückgabe | `throws` mit `WinlinkError`-Enum (assoziierte Werte für Kontext) |
| Goroutinen/Channels in Session | `async/await`, `AsyncStream` für eingehende Zeilen |
| `crypto/md5` | `CryptoKit` → `Insecure.MD5` (bewusst: Protokoll verlangt MD5) |
| `encoding/base32` | eigene kleine Base32-Hilfsfunktion (StdEncoding, RFC 4648) |
| C-artige Bit-Trickserei (LZHUF) | 1:1 nachbilden, jede Abweichung kommentieren; erst Korrektheit, dann Optimierung |
| Struct-Methoden mit Pointer-Receiver | `final class` (Session, LZHUF-State) bzw. `struct` (Message, Proposal, SID) |
| Tests table-driven | Swift Testing (`@Test`, Parametrisierung) – nicht XCTest |

**Generelle Regeln:**
- Beim Portieren immer die Go-Quelldatei im Kommentar referenzieren
  (`// Ported from wl2k-go/fbb/secure.go`).
- Zeilenenden im Protokoll: **CR** (`\r`), nicht CRLF – zentral als Konstante definieren.
- Konstanten aus Go namentlich übernehmen (`MaxBlockSize = 5`, `MaxMIDLength = 12`, …).
- Kein vorauseilendes Refactoring des Protokollverhaltens: Erst byte-kompatibel portieren,
  Verbesserungen danach als separate, benannte Commits.

---

## 5. Test-Strategie

1. **Golden Files** (aus `reference/wl2k-go/lzhuf/testdata/` nach `Tests/Fixtures/` kopieren):
   Decode `.lzh` → Vergleich mit Klartext; Encode Klartext → byteweiser Vergleich mit `.lzh`;
   Roundtrip grosser Dateien (Tom Sawyer).
2. **Portierte Unit-Tests:** Alle `*_test.go` der portierten Pakete durchgehen und übernehmen.
3. **Gescriptete Sessions:** Mock-Transport spielt aufgezeichnete CMS-Dialoge ab
   (Happy Path, Reject, Defer, Verbindungsabbruch mitten im Transfer, kaputte CRC).
4. **Live-E2E (manuell):** CLI gegen echtes CMS. Vorher optional Pat lokal laufen lassen und
   mit Wireshark/`tcpdump` eine Referenz-Session mitschneiden → als Fixture ablegen.
5. **Definition of Done pro Meilenstein:** `swift test` grün, keine Warnings unter
   Strict Concurrency, kurzes Ergebnis-Fazit.

---

## 6. Arbeitsweise mit Chris

- **Schrittweise mit Bestätigung:** Vor jedem Meilenstein kurz den Plan skizzieren,
  Freigabe abwarten. Innerhalb eines Meilensteins selbständig arbeiten.
- **Erklären statt nur liefern:** Bei Protokoll-Entscheidungen das «Warum» kurz begründen
  (Chris will Code und Systeme verstehen, bevor sie laufen).
- **Nachfragen statt raten:** Unklare Anforderungen direkt klären.
- **Commits:** klein, thematisch, englische Message im Imperativ
  (`Add LZHUF decoder with golden file tests`).
- **Keine Credentials im Repo.** `WL_CALLSIGN`/`WL_PASSWORD` nur als Env-Variablen.
- Rechtliches im Hinterkopf: Über Funk gilt später Klartext-Pflicht (keine Verschlüsselung
  auf Amateurbändern) – LZHUF/B2F ist offene Kompression, kein Problem. Für Stufe 1
  (Telnet) ohnehin irrelevant.

---

## 7. Referenzen

- B2F-Spezifikation: https://winlink.org/B2F
- Winlink Data Flow & Packaging (PDF): https://winlink.org/sites/default/files/downloads/winlink_data_flow_and_data_packaging.pdf
- wl2k-go (Referenz, MIT): https://github.com/la5nta/wl2k-go
- Pat (Client-Inspiration): https://github.com/la5nta/pat
- Offizielle LZH-Quelle (VB.NET): https://github.com/ARSFI/Winlink-Compression
- FBB-Originalprotokoll: http://www.f6fbb.org/
- Beispiel-Session (AC0KQ): https://www.rmham.org/wp-content/uploads/2022/03/3_AC0KQ-NTSGW.pdf
- Lokale Protokoll-Doku: `WINLINK-B2F-REFERENZ.md`

*73 de HB9HJI – los geht's!*
