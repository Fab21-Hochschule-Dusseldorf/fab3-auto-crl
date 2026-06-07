#!/bin/sh
# FB3-Auto - Zertifikatsantrag erzeugen (macOS / Linux)
#
#   ./request-cert.sh                 -> Schluessel + CSR erzeugen
#   ./request-cert.sh finish CERT CA  -> nach Rueckgabe: .p12 fuer Adobe Acrobat bauen
#
# Der private Schluessel bleibt IMMER auf deinem Rechner. Du schickst nur den .csr.
set -eu

ADMIN_EMAIL="michael.protogerakis@hs-duesseldorf.de"   # CA-Verwalter (Empfaenger der CSR)

err() { printf '%s\n' "$*" >&2; }
ask() { # ask "Frage" "default" -> gibt Antwort auf stdout
  _p="$1"; _d="${2:-}"
  if [ -n "$_d" ]; then printf '%s [%s]: ' "$_p" "$_d" >&2; else printf '%s: ' "$_p" >&2; fi
  IFS= read -r _a || true
  if [ -n "${_a:-}" ]; then printf '%s' "$_a"; else printf '%s' "$_d"; fi
}

command -v openssl >/dev/null 2>&1 || { err "Fehler: 'openssl' nicht gefunden."; exit 1; }

# in Zwischenablage kopieren (stdin) -> 0 wenn geklappt
to_clipboard() {
  if   command -v pbcopy  >/dev/null 2>&1; then pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then wl-copy
  elif command -v xclip   >/dev/null 2>&1; then xclip -selection clipboard
  elif command -v xsel    >/dev/null 2>&1; then xsel --clipboard --input
  else cat >/dev/null; return 1; fi
}
# minimaler URL-Encoder fuer ASCII-Text (Leerzeichen, Sonderzeichen)
enc() { printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/@/%40/g' \
        -e 's/&/%26/g' -e 's/?/%3F/g' -e 's/#/%23/g' -e 's/+/%2B/g'; }
open_url() {
  if   command -v open     >/dev/null 2>&1; then open "$1"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1
  else return 1; fi
}
reveal() {
  if   command -v open     >/dev/null 2>&1; then open -R "$1" 2>/dev/null || open "$(dirname "$1")"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$(dirname "$1")" >/dev/null 2>&1
  fi
}
mail_request() {  # $1=csr  $2=antragsteller-email
  _csr="$1"; _from="$2"
  subj=$(enc "FB3 Zertifikatsantrag - ${_from}")
  body=$(enc "Hallo Michael,")"%0D%0A%0D%0A"
  body="${body}$(enc "anbei mein Zertifikatsantrag (CSR) fuer die FB3-CA.")%0D%0A"
  body="${body}$(enc "Die Antragsdatei haengt an bzw. liegt in der Zwischenablage:")%0D%0A"
  body="${body}$(enc "$(basename "$_csr")")%0D%0A%0D%0A"
  body="${body}$(enc "Antragsteller: ${_from}")%0D%0A$(enc "Viele Gruesse")"
  if printf '%s' "$(cat "$_csr")" | to_clipboard 2>/dev/null; then
    err "-> CSR-Inhalt liegt in der Zwischenablage (im Mail-Fenster mit Cmd/Strg+V einfuegen)."
  fi
  reveal "$_csr"
  open_url "mailto:${ADMIN_EMAIL}?subject=${subj}&body=${body}" \
    && err "-> E-Mail-Entwurf geoeffnet. Bitte $(basename "$_csr") anhaengen und senden." \
    || err "-> Bitte $_csr manuell per E-Mail an ${ADMIN_EMAIL} schicken."
}

# ---------------------------------------------------------------- finish-Modus
if [ "${1:-}" = "finish" ]; then
  CRT="${2:-}"; CA="${3:-}"
  [ -n "$CRT" ] || CRT=$(ask "Pfad zum signierten Zertifikat (.crt)")
  [ -n "$CA" ]  || CA=$(ask "Pfad zur root-ca-fb3-auto.crt")
  [ -f "$CRT" ] || { err "Zertifikat nicht gefunden: $CRT"; exit 1; }
  [ -f "$CA" ]  || { err "CA-Datei nicht gefunden: $CA"; exit 1; }

  # passenden privaten Schluessel finden (Public-Key-Abgleich)
  certpub=$(openssl x509 -in "$CRT" -noout -pubkey 2>/dev/null | openssl sha256)
  KEY=""
  for k in *.key; do
    [ -f "$k" ] || continue
    kp=$(openssl pkey -in "$k" -pubout 2>/dev/null | openssl sha256 2>/dev/null || true)
    if [ "$kp" = "$certpub" ]; then KEY="$k"; break; fi
  done
  [ -n "$KEY" ] || { err "Kein passender privater Schluessel (*.key) im aktuellen Ordner gefunden."; exit 1; }

  CN=$(openssl x509 -in "$CRT" -noout -subject -nameopt oneline,utf8 | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')
  base=$(printf '%s' "$KEY" | sed 's/\.key$//')
  OUT="${base}-fb3.p12"
  err "Verwende Schluessel: $KEY"
  err "Erzeuge $OUT (du wirst gleich nach einem Export-Passwort gefragt)..."
  openssl pkcs12 -export -inkey "$KEY" -in "$CRT" -certfile "$CA" \
    -name "${CN:-FB3-CA Signatur}" -out "$OUT"
  err ""
  err "Fertig: $(pwd)/$OUT"
  err "In Adobe Acrobat: Einstellungen -> Unterschriften -> Identitaeten und vertrauenswuerdige"
  err "Zertifikate -> Digitale IDs -> Hinzufuegen -> 'Vorhandene digitale ID-Datei (PKCS#12)'."
  err "Zusaetzlich '$CA' unter Vertrauenswuerdige Zertifikate importieren und als vertrauenswuerdigen Stamm markieren."
  exit 0
fi

# --------------------------------------------------------------- request-Modus
err "=== FB3-Auto Zertifikatsantrag ==="
CN=$(ask "Vollstaendiger Name (z.B. Dr. Erika Musterfrau)")
while [ -z "$CN" ]; do CN=$(ask "Name darf nicht leer sein"); done
EMAIL=$(ask "E-Mail (hs-duesseldorf.de)")
while [ -z "$EMAIL" ]; do EMAIL=$(ask "E-Mail darf nicht leer sein"); done
ORG=$(ask "Organisation" "Hochschule Düsseldorf")
OU=$(ask "Fachbereich / OU (optional)")

base=$(printf '%s' "$EMAIL" | sed 's/@.*//; s/[^A-Za-z0-9._-]/_/g')
[ -n "$base" ] || base="antrag"
KEY="${base}.key"
CSR="${base}.csr"

if [ -f "$KEY" ]; then
  ans=$(ask "WARNUNG: $KEY existiert schon. Ueberschreiben? (j/N)")
  case "$ans" in j|J|y|Y) : ;; *) err "Abgebrochen."; exit 1;; esac
fi

CNF=$(mktemp)
{
  echo "[req]"
  echo "prompt = no"
  echo "distinguished_name = dn"
  echo "req_extensions = ext"
  echo "string_mask = utf8only"
  echo "[dn]"
  echo "CN = ${CN}"
  echo "O = ${ORG}"
  [ -n "$OU" ] && echo "OU = ${OU}"
  echo "emailAddress = ${EMAIL}"
  echo "[ext]"
  echo "keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment"
  echo "extendedKeyUsage = emailProtection"
  echo "subjectAltName = email:${EMAIL}"
} > "$CNF"

openssl genrsa -out "$KEY" 3072 2>/dev/null
chmod 600 "$KEY" 2>/dev/null || true
openssl req -new -utf8 -key "$KEY" -out "$CSR" -config "$CNF"
rm -f "$CNF"

err ""
err "Fertig:"
err "  Privater Schluessel : $(pwd)/$KEY"
err "        --> BLEIBT BEI DIR. Niemals weitergeben, nicht loeschen!"
err "  Antrag (CSR)        : $(pwd)/$CSR"
err "        --> diese eine Datei an Michael schicken."
err ""
ans=$(ask "Jetzt E-Mail-Entwurf an ${ADMIN_EMAIL} oeffnen? (J/n)")
case "$ans" in n|N) : ;; *) mail_request "$CSR" "$EMAIL" ;; esac

err ""
err "Wenn du das signierte Zertifikat zurueckbekommst:"
err "  ./request-cert.sh finish <signiert.crt> <root-ca-fb3-auto.crt>"
