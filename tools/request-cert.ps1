<#
  FB3-Auto - Zertifikatsantrag (Windows, nativ, ohne Zusatzsoftware)

    .\request-cert.ps1                              -> Schluessel + CSR erzeugen
    .\request-cert.ps1 finish -CertFile signed.cer  -> nach Rueckgabe: Zertifikat installieren
                        [-CaFile root-ca-fb3-auto.crt]

  Der private Schluessel wird sicher im Windows-Schluesselspeicher erzeugt und
  verlaesst den Rechner nie. Du schickst nur die .csr-Datei.
#>
param(
  [string]$Mode = "request",
  [string]$CertFile,
  [string]$CaFile
)

$AdminEmail = "michael.protogerakis@hs-duesseldorf.de"   # CA-Verwalter (Empfaenger der CSR)

function Read-Def($prompt, $def) {
  if ($def) { $r = Read-Host "$prompt [$def]" } else { $r = Read-Host $prompt }
  if ([string]::IsNullOrWhiteSpace($r)) { return $def } else { return $r }
}

# ----------------------------------------------------------------- finish-Modus
if ($Mode -eq "finish" -or $Mode -eq "accept") {
  if (-not $CertFile) { $CertFile = Read-Host "Pfad zum signierten Zertifikat (.cer/.crt)" }
  if (-not (Test-Path $CertFile)) { Write-Error "Datei nicht gefunden: $CertFile"; exit 1 }
  if ($CaFile -and (Test-Path $CaFile)) {
    Import-Certificate -FilePath $CaFile -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    Write-Host "Root-CA in den vertrauenswuerdigen Stammspeicher (Benutzer) importiert."
  }
  certreq -accept $CertFile
  Write-Host ""
  Write-Host "Zertifikat installiert und automatisch mit deinem privaten Schluessel verknuepft."
  Write-Host "Adobe Acrobat nutzt es ueber: Einstellungen -> Unterschriften -> Digitale IDs"
  Write-Host "-> 'Digitale Keychain-IDs' / Windows-Zertifikatspeicher."
  return
}

# ---------------------------------------------------------------- request-Modus
Write-Host "=== FB3-Auto Zertifikatsantrag ==="
$CN = Read-Def "Vollstaendiger Name (z.B. Dr. Erika Musterfrau)" ""
while (-not $CN) { $CN = Read-Def "Name darf nicht leer sein" "" }
$EMAIL = Read-Def "E-Mail (hs-duesseldorf.de)" ""
while (-not $EMAIL) { $EMAIL = Read-Def "E-Mail darf nicht leer sein" "" }
$ORG = Read-Def "Organisation" "Hochschule Duesseldorf"
$OU  = Read-Def "Fachbereich / OU (optional)" ""

$base = ($EMAIL -split "@")[0] -replace "[^A-Za-z0-9._-]","_"
if (-not $base) { $base = "antrag" }
$inf = "$base.inf"
$csr = "$base.csr"

$subject = "CN=$CN,O=$ORG"
if ($OU) { $subject += ",OU=$OU" }
$subject += ",E=$EMAIL"

# KeyUsage 0xE0 = digitalSignature (0x80) + nonRepudiation (0x40) + keyEncipherment (0x20)
# (keyEncipherment ist fuer S/MIME-Verschluesselung noetig)
# EKU 1.3.6.1.5.5.7.3.4 = E-Mail-Schutz (Acrobat-Signatur + S/MIME)
$infContent = @"
[Version]
Signature="`$Windows NT`$"

[NewRequest]
Subject = "$subject"
KeyLength = 3072
KeyAlgorithm = RSA
Exportable = TRUE
MachineKeySet = FALSE
RequestType = PKCS10
ProviderName = "Microsoft Software Key Storage Provider"
KeyUsage = 0xe0

[EnhancedKeyUsageExtension]
OID=1.3.6.1.5.5.7.3.4

[Extensions]
2.5.29.17 = "{text}"
_continue_ = "email=$EMAIL"
"@

Set-Content -Path $inf -Value $infContent -Encoding ASCII
certreq -new $inf $csr
Remove-Item $inf -ErrorAction SilentlyContinue

$csrPath = (Resolve-Path $csr).Path
Write-Host ""
Write-Host "Fertig:"
Write-Host ("  Antrag (CSR): {0}  -> diese Datei an Michael schicken" -f $csrPath)
Write-Host "  Dein privater Schluessel liegt sicher im Windows-Schluesselspeicher."
Write-Host ""

$ans = Read-Host "Jetzt E-Mail-Entwurf an $AdminEmail oeffnen? (J/n)"
if ($ans -notmatch '^[nN]') {
  try { Set-Clipboard -Value (Get-Content $csrPath -Raw)
        Write-Host "-> CSR-Inhalt in der Zwischenablage (im Mail-Fenster mit Strg+V einfuegen)." } catch {}
  try { Start-Process explorer.exe "/select,`"$csrPath`"" } catch {}
  $subj = [uri]::EscapeDataString("FB3 Zertifikatsantrag - $EMAIL")
  $body = [uri]::EscapeDataString(
    "Hallo Michael,`r`n`r`nanbei mein Zertifikatsantrag (CSR) fuer die FB3-CA.`r`n" +
    "Die Antragsdatei haengt an bzw. liegt in der Zwischenablage: $csr`r`n`r`n" +
    "Antragsteller: $EMAIL`r`nViele Gruesse")
  Start-Process "mailto:$AdminEmail`?subject=$subj`&body=$body"
  Write-Host "-> E-Mail-Entwurf geoeffnet. Bitte $csr anhaengen und senden."
}

Write-Host ""
Write-Host "Wenn du das signierte Zertifikat zurueckbekommst:"
Write-Host "  .\request-cert.ps1 finish -CertFile <signiert.cer> -CaFile root-ca-fb3-auto.crt"
