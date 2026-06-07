# fab3-auto-crl — FB3 Automatisierung PKI

Öffentliche Verteilstelle für die **Sperrliste (CRL)** und das **Stammzertifikat**
der internen CA **`root-ca-fb3-auto`** (FB3 Automatisierung, Hochschule Düsseldorf)
sowie die quelloffenen Hilfsskripte zum Beantragen/Verwalten von Zertifikaten.

> Hier liegen ausschließlich **öffentliche** PKI-Artefakte. Private Schlüssel
> (CA-Key, Nutzer-Keys) befinden sich **nicht** in diesem Repo und dürfen es nie.

## Wichtige URLs

| Zweck | URL |
|---|---|
| **CRL** (in Zertifikaten als CDP eingetragen) | `https://raw.githubusercontent.com/Fab21-Hochschule-Dusseldorf/fab3-auto-crl/main/fb3.crl` |
| **Root-CA** (als vertrauenswürdig importieren) | `https://raw.githubusercontent.com/Fab21-Hochschule-Dusseldorf/fab3-auto-crl/main/root-ca-fb3-auto.crt` |

CRL prüfen:
```sh
curl -s https://raw.githubusercontent.com/Fab21-Hochschule-Dusseldorf/fab3-auto-crl/main/fb3.crl \
  | openssl crl -inform DER -noout -lastupdate -nextupdate -issuer 2>/dev/null \
  || curl -s …/fb3.crl | openssl crl -noout -lastupdate -nextupdate -issuer
```

## Vertrauen einrichten
Damit Signaturen (Adobe Acrobat, S/MIME) als gültig gelten, einmalig
`root-ca-fb3-auto.crt` als vertrauenswürdigen Stamm importieren:
- **macOS:** doppelklicken → Schlüsselbund → bei „Vertrauen" S/MIME/X.509 auf „Immer vertrauen".
- **Windows:** in „Vertrauenswürdige Stammzertifizierungsstellen" (Benutzer) importieren.
- **Acrobat:** Einstellungen → Unterschriften → Vertrauenswürdige Zertifikate → importieren, als Stamm fürs Unterschreiben markieren.

## Tools (`tools/`)
Vollständige Anleitung: weiter unten und in den Skriptköpfen.

- `request-cert.sh` — **Kolleg:innen (macOS/Linux):** Schlüssel + Antrag (CSR) erzeugen,
  per E-Mail einsenden; `finish` baut nach Rückgabe die `.p12` für Acrobat/Mail.
- `request-cert.ps1` — **Kolleg:innen (Windows):** dasselbe nativ über `certreq`.
- `fb3-ca.sh` — **CA-Betrieb (auf der OPNsense):** `sign / list / revoke / gencrl / newca`.
- `fb3-ca.conf.example` — Konfigurationsvorlage für `fb3-ca.sh`.

### Antrag stellen (Kurzfassung)
```sh
# macOS/Linux
./tools/request-cert.sh
# Windows
powershell -ExecutionPolicy Bypass -File .\tools\request-cert.ps1
```
Der **private Schlüssel verlässt nie** deinen Rechner — eingeschickt wird nur die `.csr`.
Zurück kommt dein signiertes Zertifikat; einbinden mit `finish` (macOS/Linux) bzw.
`certreq -accept` (Windows).

## Zertifikatsprofil
End-Entity-Zertifikate: `keyUsage = digitalSignature, nonRepudiation, keyEncipherment`,
`extendedKeyUsage = emailProtection`, E-Mail im SAN, `CA:FALSE`, 3 Jahre.
Taugt für **PDF-Signatur (Acrobat)** und **S/MIME (Signieren + Verschlüsseln)**.
