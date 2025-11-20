$ErrorActionPreference = 'Stop'

$domain     = 'moneybrandclothing.com'
$githubHost = 'chyphnx.github.io'

Write-Host "=== MoneyBrand / Cloudflare Self-Heal ===" -ForegroundColor Cyan
Write-Host "[Target] $domain -> GitHub Pages ($githubHost)" -ForegroundColor Cyan

# --- TOKEN INPUT / REUSE ---
if (-not $env:MONEYBRAND_CF_TOKEN -or [string]::IsNullOrWhiteSpace($env:MONEYBRAND_CF_TOKEN)) {
    Write-Host "[CF] No token in MONEYBRAND_CF_TOKEN – prompting..." -ForegroundColor Yellow
    $sec = Read-Host "Cloudflare API token for $domain (Zone:Read + DNS:Edit)" -AsSecureString
    $b   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $tok = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
    if ([string]::IsNullOrWhiteSpace($tok)) {
        Write-Host "[CF] Empty token. Aborting." -ForegroundColor Red
        exit 1
    }
    $env:MONEYBRAND_CF_TOKEN = $tok
} else {
    Write-Host "[CF] Using existing MONEYBRAND_CF_TOKEN from env." -ForegroundColor Green
}

$headers = @{
    Authorization = "Bearer $env:MONEYBRAND_CF_TOKEN"
    'Content-Type' = 'application/json'
}

# --- ZONE LOOKUP ---
Write-Host "[CF] Looking up zone for $domain ..." -ForegroundColor Cyan
try {
    $zoneResp = Invoke-RestMethod -Method GET -Uri "https://api.cloudflare.com/client/v4/zones?name=$domain" -Headers $headers
} catch {
    Write-Host "[CF] /zones call FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Fix: check token is valid, correct Cloudflare account, Zone:Read allowed on $domain." -ForegroundColor Yellow
    exit 1
}

if (-not $zoneResp.success -or -not $zoneResp.result -or $zoneResp.result.Count -eq 0) {
    Write-Host "[CF] Zone '$domain' not found for this token." -ForegroundColor Red
    Write-Host "Fix: token must be created under the account that owns $domain with Zone:Read + DNS:Edit." -ForegroundColor Yellow
    exit 1
}

$zone   = $zoneResp.result | Where-Object { $_.name -eq $domain } | Select-Object -First 1
if (-not $zone) {
    Write-Host "[CF] API returned zones but none match $domain exactly." -ForegroundColor Red
    exit 1
}

$zoneId = $zone.id
Write-Host "[CF] Using zone id: $zoneId" -ForegroundColor Green

$baseUrl  = "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records"
$rootName = $domain
$wwwName  = "www.$domain"

# --- CLEAN CONFLICTING RECORDS ---
Write-Host "[CF] Cleaning existing A/CNAME on $rootName and $wwwName ..." -ForegroundColor Cyan
$namesToClean = @($rootName, $wwwName)
$typesToClean = @('A','CNAME')

foreach ($name in $namesToClean) {
    foreach ($type in $typesToClean) {
        $query = "type=$type&name=$([System.Uri]::EscapeDataString($name))"
        $url   = "$baseUrl`?$query"
        $existing = Invoke-RestMethod -Method GET -Uri $url -Headers $headers -ErrorAction SilentlyContinue
        if ($existing -and $existing.success -and $existing.result.Count -gt 0) {
            foreach ($rec in $existing.result) {
                Invoke-RestMethod -Method DELETE -Uri "$baseUrl/$($rec.id)" -Headers $headers -ErrorAction SilentlyContinue | Out-Null
                Write-Host "[CF] Deleted $($rec.type) $($rec.name) -> $($rec.content)" -ForegroundColor Yellow
            }
        }
    }
}

# --- APEX A RECORDS → GITHUB PAGES ---
$ghIPs = @(
    '185.199.108.153',
    '185.199.109.153',
    '185.199.110.153',
    '185.199.111.153'
)

Write-Host "[CF] Creating A records for $rootName -> GitHub Pages IPs..." -ForegroundColor Cyan
foreach ($ip in $ghIPs) {
    $body = @{
        type    = 'A'
        name    = $rootName
        content = $ip
        ttl     = 3600
        proxied = $false
    } | ConvertTo-Json
    Invoke-RestMethod -Method POST -Uri $baseUrl -Headers $headers -Body $body | Out-Null
    Write-Host "[CF] Added A $rootName -> $ip" -ForegroundColor Green
}

# --- WWW CNAME → GITHUB USER PAGES ---
Write-Host "[CF] Creating CNAME $wwwName -> $githubHost ..." -ForegroundColor Cyan
$bodyC = @{
    type    = 'CNAME'
    name    = $wwwName
    content = $githubHost
    ttl     = 3600
    proxied = $false
} | ConvertTo-Json
Invoke-RestMethod -Method POST -Uri $baseUrl -Headers $headers -Body $bodyC | Out-Null
Write-Host "[CF] Added CNAME $wwwName -> $githubHost" -ForegroundColor Green

# --- BASIC HEALTH CHECKS ---
Write-Host ""
Write-Host "[Health] Checking http://$wwwName ..." -ForegroundColor Cyan
try {
    $r1 = Invoke-WebRequest -Uri "http://$wwwName" -TimeoutSec 15 -UseBasicParsing
    Write-Host "[Health] HTTP OK: $($r1.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "[Health] HTTP check FAILED: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Likely causes: GitHub Pages not enabled on the repo, or wrong branch selected." -ForegroundColor Yellow
}

Write-Host "[Health] Checking https://$wwwName ..." -ForegroundColor Cyan
try {
    $r2 = Invoke-WebRequest -Uri "https://$wwwName" -TimeoutSec 20 -UseBasicParsing
    Write-Host "[Health] HTTPS OK (or cert still issuing): $($r2.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "[Health] HTTPS not ready yet." -ForegroundColor Yellow
    Write-Host "Action: in GitHub → Settings → Pages, confirm custom domain = $wwwName." -ForegroundColor Yellow
    Write-Host "Then wait for the certificate. Once padlock shows, enable 'Enforce HTTPS'." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== MoneyBrand / Cloudflare self-heal complete for $domain ===" -ForegroundColor Cyan
