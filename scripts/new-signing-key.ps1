# One-time: generates the update signing key pair.
#  - update-pubkey.xml  -> commit to repo (installed on clients, verifies updates)
#  - private key XML    -> store ONLY as GitHub secret UPDATE_SIGNING_KEY_XML (never commit)
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
Set-Content -Path (Join-Path $PSScriptRoot "..\update-pubkey.xml") -Value $rsa.ToXmlString($false) -Encoding ASCII
$priv = Join-Path $PSScriptRoot "..\update-private-key.xml"
Set-Content -Path $priv -Value $rsa.ToXmlString($true) -Encoding ASCII
Write-Host "Public key written to update-pubkey.xml (commit it)."
Write-Host "Private key written to update-private-key.xml - copy into the GitHub secret UPDATE_SIGNING_KEY_XML, then DELETE the file."
