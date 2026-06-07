#!/bin/sh
# ============================================================================
#  fb3-ca.sh  -  Verwaltung der FB3-Automatisierung Root-CA (laeuft auf OPNsense)
# ============================================================================
#  Unterbefehle:
#    init                 CA-Datenbank anlegen (idempotent)
#    sign <csr> [name]    Zertifikatsantrag signieren -> signed/<name>.*
#    list                 ausgestellte Zertifikate auflisten (gueltig/gesperrt)
#    show  <serial>       ein Zertifikat im Klartext anzeigen
#    revoke <serial|crt>  Zertifikat sperren  (erzeugt danach neue CRL)
#    gencrl               Sperrliste (CRL) erzeugen + ggf. veroeffentlichen
#    publish              CRL erneut zum Webserver kopieren
#    newca [subj]         NEUE Root-CA erzeugen (sicher, ueberschreibt nichts)
#    help
#
#  Einstellungen koennen in /root/fb3-ca/fb3-ca.conf ueberschrieben werden.
# ============================================================================
set -eu

# ---- Standard-Einstellungen ------------------------------------------------
CADIR=/root/fb3-ca
CACERT=/root/ca.crt
CAKEY=/root/ca.key
DEFAULT_DAYS=1095          # Gueltigkeit ausgestellter Zertifikate (3 Jahre)
CRL_DAYS=30               # Gueltigkeit der CRL (danach "abgelaufen")
CDP_URL=""               # z.B. https://raw.githubusercontent.com/<org>/<repo>/main/fb3.crl
CRL_PUBLISH=""           # scp-Ziel oder lokaler Pfad, z.B. user@web:/var/www/pki/fb3.crl
# --- Variante GitHub (Deploy-Key) ---
GIT_REPO_DIR=""          # lokaler Klon des CRL-Repos, z.B. /root/fb3-ca/repo
GIT_DEPLOY_KEY=""        # privater Deploy-Key, z.B. /root/.ssh/fab3-auto-crl-deploy
GIT_BRANCH="main"
GIT_EMAIL="ca@fb3-auto.hsd"
GIT_NAME="fb3-ca bot"

# ---- evtl. Konfig-Datei laden ----------------------------------------------
CONF="${FB3_CA_CONF:-$CADIR/fb3-ca.conf}"
[ -f "$CONF" ] && . "$CONF"
CRL_OUT="$CADIR/fb3.crl"

die() { printf 'Fehler: %s\n' "$*" >&2; exit 1; }
need_ca() {
  [ -f "$CACERT" ] || die "CA-Zertifikat fehlt: $CACERT"
  [ -f "$CAKEY" ]  || die "CA-Schluessel fehlt: $CAKEY"
}

# ---- CA-Datenbank initialisieren -------------------------------------------
init_ca() {
  need_ca
  mkdir -p "$CADIR/newcerts" "$CADIR/signed" "$CADIR/incoming"
  [ -f "$CADIR/index.txt" ]      || : > "$CADIR/index.txt"
  [ -f "$CADIR/index.txt.attr" ] || echo "unique_subject = no" > "$CADIR/index.txt.attr"
  [ -f "$CADIR/serial" ]         || echo 1001 > "$CADIR/serial"
  [ -f "$CADIR/crlnumber" ]      || echo 1001 > "$CADIR/crlnumber"
  cat > "$CADIR/openssl.cnf" <<EOF
[ca]
default_ca = fb3
[fb3]
dir              = $CADIR
certificate      = $CACERT
private_key      = $CAKEY
new_certs_dir    = \$dir/newcerts
database         = \$dir/index.txt
serial           = \$dir/serial
crlnumber        = \$dir/crlnumber
default_md       = sha256
default_days     = $DEFAULT_DAYS
default_crl_days = $CRL_DAYS
policy           = pol
copy_extensions  = none
crl_extensions   = crl_ext
[pol]
commonName             = supplied
emailAddress           = optional
organizationName       = optional
organizationalUnitName = optional
countryName            = optional
stateOrProvinceName    = optional
localityName           = optional
[crl_ext]
authorityKeyIdentifier = keyid:always
EOF
}
ensure_init() { [ -f "$CADIR/openssl.cnf" ] || init_ca; }

# ---- sign ------------------------------------------------------------------
cmd_sign() {
  need_ca; ensure_init
  CSR="${1:-}"; [ -n "$CSR" ] || die "Usage: fb3-ca.sh sign <antrag.csr> [name]"
  [ -f "$CSR" ] || die "CSR nicht gefunden: $CSR"

  echo "== Antrag pruefen ==" >&2
  openssl req -in "$CSR" -noout -verify >&2 || die "CSR-Signatur ungueltig!"
  openssl req -in "$CSR" -noout -subject -nameopt oneline,utf8 >&2

  EMAIL=$(openssl req -in "$CSR" -noout -subject -nameopt RFC2253 \
          | sed -n 's/.*emailAddress=\([^,]*\).*/\1/p' | head -1)
  name="${2:-}"
  if [ -z "$name" ]; then
    name=$(printf '%s' "$EMAIL" | sed 's/@.*//; s/[^A-Za-z0-9._-]/_/g')
    [ -n "$name" ] || name="cert"
  fi
  OUT="$CADIR/signed/${name}.crt"

  EXT=$(mktemp)
  {
    echo "[ext]"
    echo "basicConstraints = critical, CA:FALSE"
    echo "keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment"
    echo "extendedKeyUsage = emailProtection"
    echo "subjectKeyIdentifier = hash"
    echo "authorityKeyIdentifier = keyid,issuer"
    [ -n "$EMAIL" ]   && echo "subjectAltName = email:${EMAIL}"
    [ -n "$CDP_URL" ] && echo "crlDistributionPoints = URI:${CDP_URL}"
  } > "$EXT"

  openssl ca -batch -config "$CADIR/openssl.cnf" -extensions ext -extfile "$EXT" \
    -in "$CSR" -out "$OUT"
  rm -f "$EXT"

  cp "$CACERT" "$CADIR/signed/root-ca-fb3-auto.crt"
  cat "$OUT" "$CACERT" > "$CADIR/signed/${name}-fullchain.pem"
  openssl x509 -in "$OUT" -outform DER -out "$CADIR/signed/${name}.cer"
  openssl crl2pkcs7 -nocrl -certfile "$OUT" -certfile "$CACERT" \
    -out "$CADIR/signed/${name}.p7b" 2>/dev/null

  echo "" >&2
  echo "Fertig ($(openssl x509 -in "$OUT" -noout -serial)). An den Antragsteller zurueck:" >&2
  echo "  $CADIR/signed/${name}.crt           (PEM, macOS/Linux)" >&2
  echo "  $CADIR/signed/${name}.cer           (DER, Windows certreq -accept)" >&2
  echo "  $CADIR/signed/root-ca-fb3-auto.crt  (Root-CA)" >&2
  echo "  $CADIR/signed/${name}.p7b           (Cert + CA gebuendelt)" >&2
}

# ---- list ------------------------------------------------------------------
cmd_list() {
  ensure_init
  [ -s "$CADIR/index.txt" ] || { echo "(noch keine Zertifikate ausgestellt)"; return 0; }
  printf '%-8s %-7s %-14s %s\n' "SERIAL" "STATUS" "LAEUFT-AB" "SUBJEKT"
  printf '%-8s %-7s %-14s %s\n' "------" "------" "---------" "-------"
  awk -F'\t' '{
    st=$1; xp=$2; ser=$4; subj=$6;
    status=(st=="V"?"gueltig":(st=="R"?"GESPERRT":(st=="E"?"abgelaufen":st)));
    d=substr(xp,1,2)"-"substr(xp,3,2)"-"substr(xp,5,2);
    printf "%-8s %-7s 20%-12s %s\n", ser, status, d, subj;
  }' "$CADIR/index.txt"
}

# ---- show ------------------------------------------------------------------
cmd_show() {
  ensure_init
  S="${1:?Usage: fb3-ca.sh show <serial>}"
  for f in "$CADIR/newcerts/${S}.pem" "$CADIR/newcerts/$(echo "$S" | tr 'a-f' 'A-F').pem"; do
    [ -f "$f" ] && { openssl x509 -in "$f" -noout -text; return 0; }
  done
  die "Kein Zertifikat mit Serial $S gefunden."
}

# ---- revoke ----------------------------------------------------------------
cmd_revoke() {
  need_ca; ensure_init
  A="${1:?Usage: fb3-ca.sh revoke <serial|cert.crt>}"
  CRT=""
  if [ -f "$A" ]; then
    CRT="$A"
  else
    for f in "$CADIR/newcerts/${A}.pem" "$CADIR/newcerts/$(echo "$A" | tr 'a-f' 'A-F').pem"; do
      [ -f "$f" ] && { CRT="$f"; break; }
    done
  fi
  [ -n "$CRT" ] || die "Zertifikat/Serial nicht gefunden: $A"
  openssl ca -config "$CADIR/openssl.cnf" -revoke "$CRT"
  echo "Gesperrt. Erzeuge neue CRL ..." >&2
  cmd_gencrl
}

# ---- gencrl ----------------------------------------------------------------
cmd_gencrl() {
  need_ca; ensure_init
  openssl ca -config "$CADIR/openssl.cnf" -gencrl -out "$CRL_OUT"
  echo "CRL geschrieben: $CRL_OUT" >&2
  openssl crl -in "$CRL_OUT" -noout -lastupdate -nextupdate >&2
  { [ -n "$GIT_REPO_DIR" ] || [ -n "$CRL_PUBLISH" ]; } && cmd_publish
  return 0
}

# ---- publish ---------------------------------------------------------------
cmd_publish() {
  [ -f "$CRL_OUT" ] || die "Keine CRL vorhanden ($CRL_OUT) - erst 'gencrl'."
  if [ -n "$GIT_REPO_DIR" ]; then cmd_publish_git; return; fi
  [ -n "$CRL_PUBLISH" ] || die "Weder GIT_REPO_DIR noch CRL_PUBLISH gesetzt (in $CONF)."
  case "$CRL_PUBLISH" in
    *:*) scp -q "$CRL_OUT" "$CRL_PUBLISH" ;;   # user@host:/pfad
    *)   cp "$CRL_OUT" "$CRL_PUBLISH" ;;        # lokaler Pfad
  esac
  echo "CRL veroeffentlicht nach: $CRL_PUBLISH" >&2
}

# ---- publish via GitHub (Deploy-Key) ---------------------------------------
cmd_publish_git() {
  command -v git >/dev/null 2>&1 || die "git nicht installiert (pkg install git)."
  [ -d "$GIT_REPO_DIR/.git" ] || die "Kein git-Klon in $GIT_REPO_DIR."
  GSC="ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  [ -n "$GIT_DEPLOY_KEY" ] && GSC="$GSC -i $GIT_DEPLOY_KEY"
  cp "$CRL_OUT" "$GIT_REPO_DIR/fb3.crl"
  cp "$CACERT"  "$GIT_REPO_DIR/root-ca-fb3-auto.crt"
  ( cd "$GIT_REPO_DIR" || exit 1
    GIT_SSH_COMMAND="$GSC" git pull --rebase -q origin "$GIT_BRANCH" 2>/dev/null || true
    git add fb3.crl root-ca-fb3-auto.crt
    if git diff --cached --quiet; then echo "CRL unveraendert - kein Push." >&2; exit 0; fi
    git -c user.email="$GIT_EMAIL" -c user.name="$GIT_NAME" \
        commit -q -m "CRL update $(date -u +%Y-%m-%dT%H:%MZ)"
    GIT_SSH_COMMAND="$GSC" git push -q origin "$GIT_BRANCH" \
      && echo "CRL nach GitHub gepusht ($GIT_BRANCH)." >&2
  )
}

# ---- newca -----------------------------------------------------------------
cmd_newca() {
  TS=$(date +%Y%m%d-%H%M%S)
  D="$CADIR/newca-$TS"
  mkdir -p "$D"
  SUBJ="${1:-/C=DE/ST=NRW/L=Duesseldorf/O=HSD/OU=FB3 Automatisierung/CN=root-ca-fb3-auto/emailAddress=michael.protogerakis@hs-duesseldorf.de}"
  echo "Erzeuge neue Root-CA in $D" >&2
  echo "Subject: $SUBJ" >&2
  openssl req -x509 -new -newkey rsa:4096 -nodes \
    -keyout "$D/ca.key" -out "$D/ca.crt" -days 3650 -sha256 -utf8 \
    -subj "$SUBJ" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
  chmod 600 "$D/ca.key"
  echo "" >&2
  echo "Neue CA liegt in: $D/ca.crt  +  $D/ca.key" >&2
  echo "Die aktive CA ($CACERT) wurde NICHT veraendert." >&2
  echo "Zum Aktivieren (ALT zuerst sichern!):" >&2
  echo "  cp $CACERT ${CACERT}.bak-$TS; cp $CAKEY ${CAKEY}.bak-$TS" >&2
  echo "  cp $D/ca.crt $CACERT; cp $D/ca.key $CAKEY" >&2
  echo "  rm -rf $CADIR/index.txt $CADIR/serial $CADIR/crlnumber $CADIR/newcerts $CADIR/openssl.cnf  # frische DB" >&2
}

# ---- dispatch --------------------------------------------------------------
CMD="${1:-help}"; shift 2>/dev/null || true
case "$CMD" in
  init)    init_ca; echo "CA-Datenbank bereit in $CADIR" ;;
  sign)    cmd_sign "$@" ;;
  list)    cmd_list ;;
  show)    cmd_show "$@" ;;
  revoke)  cmd_revoke "$@" ;;
  gencrl)  cmd_gencrl ;;
  publish) cmd_publish ;;
  newca)   cmd_newca "$@" ;;
  help|*)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
