<#
verify_origin_private.ps1

Demuestra que el origen S3 rechaza el acceso anonimo directo mientras CloudFront
sirve el mismo objeto.

POR QUE ESTE SCRIPT CAMBIO (CLOUD-8, 22 sep 2026)
-------------------------------------------------
La version anterior terminaba en INCONCLUSIVE y remitia a un "red check" que
consistia en hacer publico un objeto a proposito. Ese camino esta CERRADO en
este bucket: tiene ACLs deshabilitados (Bucket owner enforced) y Block Public
Access completo, asi que no hay mecanismo para conceder lectura publica. El
procedimiento que existia para demostrar que el control puede fallar estaba
bloqueado por el propio control.

El INCONCLUSIVE nacia de mezclar dos preguntas en una sola lectura: un 403
anonimo significa "denegado" y tambien "no existe". Se separan:

  existencia  -> se prueba CON credenciales de dueno (aws s3api head-object).
                 Probar que algo existe es lo que un dueno puede hacer y un
                 desconocido no.
  coordenada  -> se toma de `terraform output`, no de argumentos escritos a
                 mano. Un error de tecleo deja de ser posible por construccion.
  denegacion  -> se prueba SIN credenciales, con una peticion HTTP normal.
  la sonda    -> que sabe devolver algo distinto de 403 lo demuestra la propia
                 sonda del CDN en cada corrida, devolviendo 200 con el objeto
                 correcto. Ese es el red check, y ya se cumple sin crear ni
                 debilitar nada.

NOTA SOBRE EL GUARDIA DE CREDENCIALES QUE ESTABA AQUI
-----------------------------------------------------
La version anterior se negaba a correr si habia AWS_ACCESS_KEY_ID, AWS_PROFILE
o AWS_SESSION_TOKEN en el entorno. Ese guardia se retira a proposito, y no por
comodidad:

  1. Solo miraba variables de entorno. Unas credenciales en ~/.aws/credentials
     lo atraviesan sin activarlo, que es exactamente el caso de esta maquina.
     Un guardia que no detecta el caso normal da una garantia que no tiene.
  2. No hacia falta. Invoke-WebRequest no firma peticiones con SigV4 bajo
     ninguna circunstancia: la sonda es anonima por construccion, no por
     configuracion del entorno.

La anonimidad de las sondas 1-4 se sostiene en que son HTTP sin firmar. El
unico paso que usa credenciales es head-object, y lo dice en pantalla.

Uso:
  .\verify_origin_private.ps1                      # toma todo de terraform output
  .\verify_origin_private.ps1 -Key otra/llave.txt
  .\verify_origin_private.ps1 -OriginUrl https://b.s3.r.amazonaws.com/k -Dist d.cloudfront.net
#>

param(
  [string]$Key,
  [string]$OriginUrl,
  [string]$Dist
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Continue'

function Get-TfOutput {
  param([string]$Name)
  $v = & terraform output -raw $Name 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $v) { return $null }
  return ($v | Out-String).Trim()
}

# ---------- coordenada ----------
Write-Host "== coordenada =="
if (-not $OriginUrl) {
  $OriginUrl = Get-TfOutput 'origin_url'
  if ($OriginUrl) { Write-Host "  origin_url  <- terraform output" }
}
if (-not $Dist) {
  $Dist = Get-TfOutput 'distribution_domain_name'
  if ($Dist) { Write-Host "  cdn domain  <- terraform output" }
}

if (-not $OriginUrl -or -not $Dist) {
  Write-Host ""
  Write-Host "ABORTA: no se pudo obtener la coordenada."
  Write-Host "        Corre esto dentro del directorio de Terraform, o pasa"
  Write-Host "        -OriginUrl y -Dist explicitamente."
  Write-Host "        Escribirlos a mano reintroduce el error de tecleo que este"
  Write-Host "        script existe para descartar, asi que hazlo solo a sabiendas."
  exit 2
}

$originBase = $OriginUrl.Substring(0, $OriginUrl.LastIndexOf('/'))
$defaultKey = $OriginUrl.Substring($OriginUrl.LastIndexOf('/') + 1)
if (-not $Key) { $Key = $defaultKey }

# bucket y region salen del host del origen, no de argumentos sueltos
$originHost = ([Uri]$originBase).Host
$bucket = $null; $region = $null
if ($originHost -match '^(?<b>.+?)\.s3[.-](?<r>[a-z0-9-]+)\.amazonaws\.com$') {
  $bucket = $Matches['b']; $region = $Matches['r']
} elseif ($originHost -match '^(?<b>.+?)\.s3\.amazonaws\.com$') {
  $bucket = $Matches['b']; $region = 'us-east-1'
}

$cdn    = "https://$Dist"
$absent = "__this_key_does_not_exist_$([guid]::NewGuid().ToString('N'))__"

Write-Host "  origin      : $originBase"
Write-Host "  cdn         : $cdn"
Write-Host "  key         : $Key"
Write-Host "  bucket      : $(if ($bucket) { $bucket } else { '<no deducido>' })"
Write-Host "  region      : $(if ($region) { $region } else { '<no deducido>' })"
Write-Host ""

# ---------- existencia, CON credenciales ----------
Write-Host "== existencia (usa tus credenciales de AWS) =="
$exists = 'UNKNOWN'; $etag = ''; $size = ''
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
  Write-Host "  NO VERIFICADO: la CLI de AWS no esta disponible en el PATH."
} elseif (-not $bucket) {
  Write-Host "  NO VERIFICADO: no se pudo deducir bucket/region del host del origen."
} else {
  $raw = & aws s3api head-object --bucket $bucket --key $Key --region $region --output json 2>&1
  if ($LASTEXITCODE -eq 0) {
    try {
      $j = ($raw | Out-String) | ConvertFrom-Json
      $etag = $j.ETag; $size = $j.ContentLength
    } catch { }
    $exists = 'YES'
    Write-Host "  EXISTE  s3://$bucket/$Key"
    if ($size) { Write-Host "          ContentLength: $size" }
    if ($etag) { Write-Host "          ETag         : $etag" }
  } else {
    $msg = ($raw | Out-String).Trim()
    if ($msg -match '404|Not Found') {
      $exists = 'NO'
      Write-Host "  NO EXISTE  s3://$bucket/$Key  (head-object devolvio 404)"
    } else {
      Write-Host "  NO VERIFICADO: head-object fallo por una razon distinta de 404."
      Write-Host "  $msg"
    }
  }
}
Write-Host ""

# ---------- denegacion, SIN credenciales ----------
Write-Host "== sondas anonimas (HTTP sin firmar; ninguna credencial interviene) =="

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

$pOrigin    = Get-Probe "$originBase/$Key"
$pAbsent    = Get-Probe "$originBase/$absent"
$pCdn       = Get-Probe "$cdn/$Key"
$pCdnAbsent = Get-Probe "$cdn/$absent"

"  {0,-44} {1}" -f "1. origin, llave real        (esperado 403)", $pOrigin.Code
"  {0,-44} {1}" -f "2. origin, llave ausente     (esperado 403)", $pAbsent.Code
"  {0,-44} {1}" -f "3. cdn,    llave real        (esperado 200)", $pCdn.Code
"  {0,-44} {1}" -f "4. cdn,    llave ausente (esperado 403 o 404)", $pCdnAbsent.Code
Write-Host ""

if ($pCdn.Bytes) {
  $sha = ([Security.Cryptography.SHA256]::Create().ComputeHash($pCdn.Bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  Write-Host "  sha256 servido por el CDN : $sha"
  Write-Host "  bytes recibidos           : $($pCdn.Bytes.Length)"
  Write-Host "  Comparalo con el archivo que subiste. Bytes, no apariencia."
  Write-Host ""
}

# ---------- veredicto ----------
Write-Host "== veredicto =="
$fail = 0

# el red check, que ya no necesita montaje aparte
if ($pCdn.Code -eq 200) {
  Write-Host "  RED CHECK OK   la sonda devolvio 200 en el caso 3, con el objeto real."
  Write-Host "                 Queda demostrado que sabe reportar algo distinto de 403,"
  Write-Host "                 asi que sus 403 son lecturas y no un semaforo pintado."
} else {
  Write-Host "  RED CHECK FALLA  ninguna sonda devolvio 200 en esta corrida."
  Write-Host "                   Sin eso, ningun 403 de abajo significa nada."
  $fail = 1
}
Write-Host ""

if ($pOrigin.Code -ne 403) {
  Write-Host "  FAIL   el origen respondio $($pOrigin.Code), no 403."
  Write-Host "         El bucket es alcanzable directamente. Eso rompe la invariante."
  $fail = 1
} elseif ($exists -eq 'YES') {
  Write-Host "  PASS   el objeto EXISTE en s3://$bucket/$Key, probado con credenciales"
  Write-Host "         de dueno, y el acceso anonimo a esa misma coordenada devuelve 403."
  Write-Host "         El 403 es una DENEGACION, no un fallo de busqueda."
  Write-Host "         La coordenada salio de terraform output, asi que tampoco puede"
  Write-Host "         ser un error de tecleo."
} elseif ($exists -eq 'NO') {
  Write-Host "  SIN VALOR  el objeto no existe en esa coordenada, asi que el 403 anonimo"
  Write-Host "             no dice nada sobre la politica. Corre con una llave que exista."
  $fail = 1
} else {
  Write-Host "  INCONCLUSIVE   no se pudo probar la existencia del objeto por una via"
  Write-Host "                 independiente, asi que el 403 anonimo sigue significando"
  Write-Host "                 'denegado' o 'no existe' sin poder distinguirlos."
  Write-Host "                 Resuelvelo haciendo que head-object funcione; no registres"
  Write-Host "                 un pase con esta lectura."
}

Write-Host ""
Write-Host "  Registra esta salida en CLOUD-5."
exit $fail
