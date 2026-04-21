#!/bin/bash
# expose-backup.sh
#
# Creates a tar.gz of the hoxmedia.net webroot + MySQL dump and places it
# inside the webroot with a random filename, so Claude (sandbox) can grab
# it over HTTPS. Auto-deletes after 30 minutes.
#
# Run on the server from your SSH session:
#   curl -fsSL https://raw.githubusercontent.com/diamanthoxha/hoxmedia.net/claude/sync-hoxmedia-github-xP7fJ/tools/expose-backup.sh | bash

set -e

say()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n'  "$*"; }
err()  { printf '\033[1;31mERR %s\033[0m\n'  "$*"; }

# ---------- 1. Find webroot ----------
say "Detecting webroot..."
WEBROOT=""
for p in \
    "$HOME/htdocs/hoxmedia.net" \
    "$HOME/htdocs" \
    "$HOME/domains/hoxmedia.net/public_html" \
    "$HOME/domains/hoxmedia.net/htdocs" \
    "$HOME/public_html" \
    "$HOME/www/hoxmedia.net" \
    "$HOME/www" \
    "/var/www/hoxmedia.net" \
    "/var/www/html"
do
    if [ -f "$p/index.php" ] || [ -f "$p/index.html" ]; then
        WEBROOT="$p"; break
    fi
done
if [ -z "$WEBROOT" ]; then
    WEBROOT=$(find "$HOME" -maxdepth 5 -name "index.php" 2>/dev/null | head -1 | xargs -I{} dirname {} 2>/dev/null)
fi
if [ -z "$WEBROOT" ] || [ ! -d "$WEBROOT" ]; then
    err "Could not auto-detect webroot. Paste output of 'ls -la ~' back to Claude."
    exit 1
fi
say "Webroot: $WEBROOT"

# ---------- 2. Find DB credentials ----------
say "Looking for DB credentials..."
DB_NAME=""; DB_USER=""; DB_PASS=""; DB_HOST=""

# WordPress
if [ -f "$WEBROOT/wp-config.php" ]; then
    DB_NAME=$(grep -oP "DB_NAME['\"][^'\"]*['\"]\s*,\s*['\"]\K[^'\"]+" "$WEBROOT/wp-config.php" | head -1)
    DB_USER=$(grep -oP "DB_USER['\"][^'\"]*['\"]\s*,\s*['\"]\K[^'\"]+" "$WEBROOT/wp-config.php" | head -1)
    DB_PASS=$(grep -oP "DB_PASSWORD['\"][^'\"]*['\"]\s*,\s*['\"]\K[^'\"]+" "$WEBROOT/wp-config.php" | head -1)
    DB_HOST=$(grep -oP "DB_HOST['\"][^'\"]*['\"]\s*,\s*['\"]\K[^'\"]+" "$WEBROOT/wp-config.php" | head -1)
fi
# Laravel / .env
if [ -z "$DB_NAME" ] && [ -f "$WEBROOT/.env" ]; then
    DB_NAME=$(grep -oP '^DB_(DATABASE|NAME)=\K.+' "$WEBROOT/.env" | head -1 | tr -d '"'"'")
    DB_USER=$(grep -oP '^DB_USERNAME=\K.+' "$WEBROOT/.env" | head -1 | tr -d '"'"'")
    DB_PASS=$(grep -oP '^DB_PASSWORD=\K.+' "$WEBROOT/.env" | head -1 | tr -d '"'"'")
    DB_HOST=$(grep -oP '^DB_HOST=\K.+' "$WEBROOT/.env" | head -1 | tr -d '"'"'")
fi
# Generic config.php
if [ -z "$DB_NAME" ] && [ -f "$WEBROOT/config.php" ]; then
    DB_NAME=$(grep -oiE "(db_?name|database)\s*=\s*['\"][^'\"]+" "$WEBROOT/config.php" | grep -oE "['\"][^'\"]+\$" | tr -d "\"'" | head -1)
    DB_USER=$(grep -oiE "db_?user\s*=\s*['\"][^'\"]+"           "$WEBROOT/config.php" | grep -oE "['\"][^'\"]+\$" | tr -d "\"'" | head -1)
    DB_PASS=$(grep -oiE "db_?pass(word)?\s*=\s*['\"][^'\"]+"    "$WEBROOT/config.php" | grep -oE "['\"][^'\"]+\$" | tr -d "\"'" | head -1)
fi

DB_HOST=${DB_HOST:-localhost}

# ---------- 3. Dump DB ----------
DB_DUMP=""
if [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]; then
    say "Dumping database '$DB_NAME' from $DB_HOST as '$DB_USER'..."
    DB_DUMP=$(mktemp --suffix=.sql)
    if MYSQL_PWD="$DB_PASS" mysqldump \
            --single-transaction --routines --triggers --events \
            -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" > "$DB_DUMP" 2>/tmp/mysqldump.err; then
        say "DB dump OK: $(du -h "$DB_DUMP" | cut -f1)"
    else
        warn "mysqldump failed:"
        cat /tmp/mysqldump.err
        rm -f "$DB_DUMP"; DB_DUMP=""
    fi
else
    warn "DB credentials not auto-detected from wp-config.php/.env/config.php."
    warn "The archive will contain files only. You can dump the DB manually."
fi

# ---------- 4. Build archive ----------
TOKEN=$(head -c 8 /dev/urandom | xxd -p)
OUT="$WEBROOT/hox-sync-$TOKEN.tar.gz"
say "Creating archive at $OUT..."
STAGE=$(mktemp -d)
if [ -n "$DB_DUMP" ]; then
    cp "$DB_DUMP" "$STAGE/database.sql"
    rm -f "$DB_DUMP"
fi
tar czf "$OUT" \
    --exclude="hox-sync-*.tar.gz" \
    -C "$WEBROOT" . \
    $( [ -n "$DB_DUMP" ] && echo "-C $STAGE database.sql" )
rm -rf "$STAGE"
chmod 644 "$OUT"
SIZE=$(du -h "$OUT" | cut -f1)
say "Archive ready ($SIZE)"

# ---------- 5. Print URL + schedule self-destruct ----------
URL="https://hoxmedia.net/$(basename "$OUT")"
echo
echo "============================================================"
echo " SEND THIS URL TO CLAUDE:"
echo
echo "   $URL"
echo
echo " Size: $SIZE"
echo " The file will self-delete in 30 minutes for security."
echo "============================================================"
echo

# Background cleanup
nohup bash -c "sleep 1800; rm -f '$OUT'" >/dev/null 2>&1 &
disown 2>/dev/null || true
