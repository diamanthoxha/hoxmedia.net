# sync-from-server.ps1
#
# Pulls the full hoxmedia.net site (webroot + MySQL database) from the
# production server to this local folder, commits to the current git branch,
# and pushes to GitHub.
#
# Run from:  C:\Users\diama\Desktop\hoxmedia.net
# Usage:     powershell -ExecutionPolicy Bypass -File .\sync-from-server.ps1
#
# Requires:  OpenSSH client (built into Windows 10/11), git, and a running
#            ssh-agent OR a ~/.ssh/id_* key OR you'll be prompted for the
#            root password several times (use an SSH key to avoid this).

$ErrorActionPreference = 'Stop'

# ---------- CONFIG ----------
$SshHost   = 'root@hoxmedia.net'
$WebRoot   = '/var/www/html'          # <-- change if your docroot is elsewhere
$DbName    = 'hoxmedia'               # <-- change to your actual DB name
$DbUser    = 'root'                   # <-- change to your DB user
# DB password is read from env var $env:HOX_DB_PASS (do NOT hardcode it).
# Set it once in this shell:   $env:HOX_DB_PASS = 'your-mysql-password'
# ----------------------------

$LocalServerDir = Join-Path $PSScriptRoot 'server-source'
$LocalDbDump    = Join-Path $PSScriptRoot 'db\hoxmedia.sql'

Write-Host "==> 1/5  Detecting webroot on the server..." -ForegroundColor Cyan
# Quick sanity check - let you override if $WebRoot is wrong
$probe = ssh -o StrictHostKeyChecking=accept-new $SshHost "test -d $WebRoot && echo OK || echo MISSING"
if ($probe -notmatch 'OK') {
    Write-Warning "Webroot $WebRoot not found on server. Common locations:"
    ssh $SshHost "ls -d /var/www/* /home/*/public_html /srv/www/* 2>/dev/null"
    throw "Set `$WebRoot at the top of this script to the correct path and re-run."
}

Write-Host "==> 2/5  Copying webroot from $SshHost`:$WebRoot ..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $LocalServerDir | Out-Null
# -r recursive, -p preserve mtimes, compress in transit
scp -r -p -C "$SshHost`:$WebRoot/*" "$LocalServerDir/"
if ($LASTEXITCODE -ne 0) { throw "scp failed" }

Write-Host "==> 3/5  Dumping MySQL database '$DbName' on server..." -ForegroundColor Cyan
if (-not $env:HOX_DB_PASS) {
    Write-Warning "Env var HOX_DB_PASS is not set. You'll be prompted for the MySQL password."
}
New-Item -ItemType Directory -Force -Path (Split-Path $LocalDbDump) | Out-Null

$remoteDumpPath = "/tmp/hoxmedia_$(Get-Date -Format yyyyMMdd_HHmmss).sql"
$dumpCmd = if ($env:HOX_DB_PASS) {
    # pass via env to avoid it showing in `ps`
    "MYSQL_PWD='$($env:HOX_DB_PASS)' mysqldump --single-transaction --routines --triggers --events -u $DbUser $DbName > $remoteDumpPath"
} else {
    "mysqldump --single-transaction --routines --triggers --events -u $DbUser -p $DbName > $remoteDumpPath"
}
ssh $SshHost $dumpCmd
if ($LASTEXITCODE -ne 0) { throw "mysqldump failed on server" }

Write-Host "==> 4/5  Downloading dump and cleaning up server..." -ForegroundColor Cyan
scp -C "$SshHost`:$remoteDumpPath" $LocalDbDump
ssh $SshHost "rm -f $remoteDumpPath"

Write-Host "==> 5/5  Committing and pushing..." -ForegroundColor Cyan
# Make sure giant/secret things don't land in the repo
$gitignorePath = Join-Path $PSScriptRoot '.gitignore'
$gitignoreEntries = @(
    '# Added by sync-from-server.ps1',
    'server-source/**/.env',
    'server-source/**/.env.*',
    'server-source/**/wp-config.php',
    'server-source/**/config.php',
    'server-source/**/*.log',
    '*.sql.gz'
)
if (-not (Test-Path $gitignorePath) -or -not (Select-String -Path $gitignorePath -Pattern 'sync-from-server.ps1' -Quiet)) {
    Add-Content -Path $gitignorePath -Value $gitignoreEntries
}

git add -A
$sizeMb = [math]::Round((Get-ChildItem -Recurse $LocalServerDir,$LocalDbDump -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB, 1)
git commit -m "Sync server webroot + DB dump from hoxmedia.net (~$sizeMb MB)"
git push -u origin (git rev-parse --abbrev-ref HEAD)

Write-Host ""
Write-Host "Done. Review before pushing secrets:" -ForegroundColor Green
Write-Host "  - server-source\  (full PHP source + uploads)"
Write-Host "  - db\hoxmedia.sql (MySQL dump)"
Write-Host ""
Write-Host "IMPORTANT: open server-source\ and check any .env, wp-config.php,"
Write-Host "config.php, or credentials.json files before they end up on GitHub."
