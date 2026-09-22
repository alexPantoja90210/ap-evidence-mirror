<#
verify_origin_private.ps1 — equivalente en PowerShell de verify_origin_private.sh

Comprueba, desde fuera de la cuenta y sin credenciales, que el origen S3 rechaza
el acceso anonimo directo mientras CloudFront sirve el mismo objeto.

Reporta TRES resultados, no dos. El tercero existe porque en un bucket con Block
Public Access encendido, S3 responde 403 a una peticion anonima por un objeto que
NO EXISTE, igual que por uno que existe y esta denegado. Un 403 a secas no prueba
nada por si solo: un error de tecleo en el bucket, la region o la llave produce
el mismo codigo que una politica que funciona.

Probado en Windows PowerShell 5.1. Dos detalles de esa version estan resueltos
aqui a proposito: Invoke-WebRequest -OutFile no devuelve objeto en 5.1, asi que
el cuerpo se toma de RawContentStream y se escribe como bytes; y la llave
inexistente se construye con un GUID y no con una marca de tiempo, porque
Get-Date -UFormat %s depende del separador decimal de la configuracion regional.

Uso:
  .\verify_origin_private.ps1 <bucket> <region> <dominio-cloudfront> [llave]
#>

param(
  [Parameter(Mandatory=$true)][string]$Bucket,
  [Parameter(Mandatory=$true)][string]$Region,
  [Parameter(Mandatory=$true)][string]$Dist,
  [string]$Key = "index.html"
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$creds = @($env:AWS_ACCESS_KEY_ID, $env:AWS_PROFILE, $env:AWS_SESSION_TOKEN) | Where-Object { $_ }
if ($creds) {
  Write-Host "REFUSED: hay credenciales de AWS en este entorno."
  Write-Host "         Esta comprobacion debe correr como lo haria un desconocido."
  Write-Host "         Limpialas y vuelve a correr."
  exit 2
}

$absent = "__this_key_does_not_exist_$([guid]::NewGuid().ToString('N'))__"
$origin = "https://$Bucket.s3.$Region.amazonaws.com"
$cdn    = "https://$Dist"

function Get-Probe {
  param([string]$Url)
  try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
    $bytes = $null
    if ($r.RawContentStream) { $bytes = $r.RawContentStream.ToArray() }
    return [pscustomobject]@{ Code = [int]$r.StatusCode; Bytes = $bytes }
  } catch {
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    return [pscustomobject]@{ Code = $code; Bytes = $null }
  }
}

Write-Host "origin : $origin"
Write-Host "cdn    : $cdn"
Write-Host "key    : $Key"
Write-Host ""

$pOrigin    = Get-Probe "$origin/$Key"
$pAbsent    = Get-Probe "$origin/$absent"
$pCdn       = Get-Probe "$cdn/$Key"
$pCdnAbsent = Get-Probe "$cdn/$absent"

"{0,-46} {1}" -f "1. origin, real key          (want 403)", $pOrigin.Code
"{0,-46} {1}" -f "2. origin, absent key        (want 403)", $pAbsent.Code
"{0,-46} {1}" -f "3. cdn,    real key          (want 200)", $pCdn.Code
"{0,-46} {1}" -f "4. cdn,    absent key   (want 403 or 404)", $pCdnAbsent.Code
Write-Host ""

$fail = 0

if ($pCdn.Code -ne 200) {
  Write-Host "FAIL  el CDN no sirve el objeto. Nada de lo de abajo significa nada."
  exit 1
}
Write-Host "PASS  el CDN sirve el objeto."
if ($pCdn.Bytes) {
  $sha256 = [Security.Cryptography.SHA256]::Create()
  $hash = ($sha256.ComputeHash($pCdn.Bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  Write-Host "      sha256 tal como se sirve: $hash"
  Write-Host "      bytes recibidos         : $($pCdn.Bytes.Length)"
  Write-Host "      comparalo con el archivo que subiste. Bytes, no apariencia."
} else {
  Write-Host "      (no se pudo leer el cuerpo para calcular el sha256)"
}
Write-Host ""

if ($pOrigin.Code -ne 403) {
  Write-Host "FAIL  el origen respondio $($pOrigin.Code), no 403. El bucket es alcanzable directamente."
  $fail = 1
} elseif ($pAbsent.Code -eq 403) {
  Write-Host "INCONCLUSIVE  el origen devuelve 403 para la llave real Y para una que no"
  Write-Host "              puede existir. Es el comportamiento esperado de S3 con Block"
  Write-Host "              Public Access encendido, y significa que esta lectura por si"
  Write-Host "              sola no distingue una politica que funciona de un bucket o"
  Write-Host "              una region mal escritos."
  Write-Host ""
  Write-Host "              Resuelvelo con el red check de abajo. NO registres un pase"
  Write-Host "              hasta haber visto esa sonda devolver 200."
} else {
  Write-Host "PASS  el origen rechaza la llave real (403) y responde $($pAbsent.Code) para una"
  Write-Host "      ausente, asi que el 403 es una denegacion y no un fallo de busqueda."
}

@'

--- EL RED CHECK, y no es opcional ---------------------------------------------
Una comprobacion que no puede fallar no prueba nada.

  1. En la consola, sube un objeto desechable, p. ej. redcheck.txt.
  2. Dale lectura publica, a proposito.
  3. Corre:  .\verify_origin_private.ps1 <bucket> <region> <dist> redcheck.txt
     La sonda 1 TIENE que volver 200. Si sigue diciendo 403, la sonda esta mal,
     no la politica, y todas las demas lecturas de este archivo no valen nada.
  4. Quita el permiso. Vuelve a correr. La sonda 1 TIENE que volver a 403.
  5. Borra redcheck.txt.

Registra las tres lecturas en CLOUD-5. Sin la de en medio tienes un numero,
no evidencia.
--------------------------------------------------------------------------------
'@

exit $fail
