$ErrorActionPreference = 'Stop'

$domain     = 'moneybrandclothing.com'
$githubHost = 'chyphnx.github.io'
$wwwName    = "www.$domain"

Write-Host "=== MoneyBrand Full Deploy (Git + DNS + Health) ===" -ForegroundColor Cyan
Write-Host "[Target] $domain / $wwwName -> GitHub Pages ($githubHost)" -ForegroundColor Cyan

# ---------------- STEP 1: GIT SYNC ----------------
Write-Host "`n[Step 1] Syncing Git repo..." -ForegroundColor Cyan
try {
    git fetch origin 2>$null
    git reset --hard origin/main
    Write-Host "[Git] Synced to origin/main." -ForegroundColor Green
} catch {
    Write-Host "[Git] WARNING: git sync failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ---------------- STEP 2: CNAME FOR GITHUB PAGES ----------------
Write-Host "`n[Step 2] Ensuring CNAME file for GitHub Pages..." -ForegroundColor Cyan
try {
    Set-Content -Path '.\CNAME' -NoNewline -Value $wwwName
    Write-Host "[GitHub] CNAME set to $wwwName" -ForegroundColor Green
} catch {
    Write-Host "[GitHub] Failed to write CNAME: $($_.Exception.Message)" -ForegroundColor Red
}

# ---------------- STEP 3: CLOUDFLARE DNS SELF-HEAL ----------------
Write-Host "`n[Step 3] Cloudflare DNS self-heal..." -ForegroundColor Cyan

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

Write-Host "[CF] Looking up zone for $domain ..." -ForegroundColor Cyan
try {
    $zoneResp = Invoke-RestMethod -Method GET -Uri "https://api.cloudflare.com/client/v4/zones?name=$domain" -Headers $headers
} catch {
    Write-Host "[CF] /zones call FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Fix: token must be valid and have Zone:Read on the account that owns $domain." -ForegroundColor Yellow
    exit 1
}

if (-not $zoneResp.success -or -not $zoneResp.result -or $zoneResp.result.Count -eq 0) {
    Write-Host "[CF] Zone '$domain' not found for this token." -ForegroundColor Red
    Write-Host "Fix: create a scoped token with Zone:Read + DNS:Edit on $domain." -ForegroundColor Yellow
    exit 1
}

$zone = $zoneResp.result | Where-Object { $_.name -eq $domain } | Select-Object -First 1
if (-not $zone) {
    Write-Host "[CF] API returned zones but none match $domain exactly." -ForegroundColor Red
    exit 1
}

$zoneId = $zone.id
Write-Host "[CF] Using zone id: $zoneId" -ForegroundColor Green

$baseUrl  = "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records"
$rootName = $domain

Write-Host "[CF] Cleaning existing A/CNAME on $rootName and $wwwName ..." -ForegroundColor Cyan
$namesToClean = @($rootName, $wwwName)
$typesToClean = @('A','CNAME')

foreach ($name in $namesToClean) {
    foreach ($type in $typesToClean) {
        $query    = "type=$type&name=$([System.Uri]::EscapeDataString($name))"
        $url      = "$baseUrl`?$query"
        $existing = Invoke-RestMethod -Method GET -Uri $url -Headers $headers -ErrorAction SilentlyContinue
        if ($existing -and $existing.success -and $existing.result.Count -gt 0) {
            foreach ($rec in $existing.result) {
                Invoke-RestMethod -Method DELETE -Uri "$baseUrl/$($rec.id)" -Headers $headers -ErrorAction SilentlyContinue | Out-Null
                Write-Host "[CF] Deleted $($rec.type) $($rec.name) -> $($rec.content)" -ForegroundColor Yellow
            }
        }
    }
}

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

# ---------------- STEP 4: HEALTH CHECKS ----------------
Write-Host "`n[Step 4] Health checks..." -ForegroundColor Cyan

try {
    $r1 = Invoke-WebRequest -Uri "http://$wwwName" -TimeoutSec 15 -UseBasicParsing
    Write-Host "[Health] HTTP OK: $($r1.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "[Health] HTTP check FAILED: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Likely causes: GitHub Pages not enabled or branch not set to main/root." -ForegroundColor Yellow
}

try {
    $r2 = Invoke-WebRequest -Uri "https://$wwwName" -TimeoutSec 20 -UseBasicParsing
    Write-Host "[Health] HTTPS OK (or cert still issuing): $($r2.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "[Health] HTTPS not ready yet." -ForegroundColor Yellow
    Write-Host "Action: GitHub → Settings → Pages: set custom domain = $wwwName, then wait for cert and enable 'Enforce HTTPS'." -ForegroundColor Yellow
}

Write-Host "`n=== MoneyBrand full deploy completed for $domain ===" -ForegroundColor Cyan
