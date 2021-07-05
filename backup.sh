#!/bin/bash

set -ex

if [ -f "$1" ]; then
    source "$1"
else
    echo First argument must be your backup.conf
    exit 1
fi

BACKUP_ROOT="${VAULTWARDEN_ROOT}/backup"
BACKUP_DIR_PATH="${BACKUP_ROOT}/${BACKUP_DIR_NAME}"
BACKUP_FILE_PATH="${BACKUP_ROOT}/archives/${BACKUP_DIR_NAME}.7z"

cd "${VAULTWARDEN_ROOT}"
mkdir -p "${BACKUP_DIR_PATH}"

# Back up the database using the Online Backup API (https://www.sqlite.org/backup.html)
# as implemented in the SQLite CLI. However, if a call to sqlite3_backup_step() returns
# one of the transient errors SQLITE_BUSY or SQLITE_LOCKED, the CLI doesn't retry the
# backup step; instead, it simply stops the backup and returns an error. This is unlikely,
# but to minimize the possibility of a failed backup, implement a retry mechanism here.
max_tries=10
tries=0
until sqlite3 "file:${DATA_DIR}/${DB_FILE}?mode=ro" ".backup '${BACKUP_DIR_PATH}/${DB_FILE}'"; do
    if (( ++tries >= max_tries )); then
        echo "Aborting after ${max_tries} failed backup attempts..."
        exit 1
    fi
    echo "Backup failed. Retry #${tries}..."
    rm -f "${BACKUP_DIR_PATH}/${DB_FILE}"
    sleep 1
done

backup_files=()
for f in attachments config.json rsa_key.der rsa_key.pem rsa_key.pub.der sends; do
    if [[ -e "${DATA_DIR}"/$f ]]; then
        backup_files+=("${DATA_DIR}"/$f)
    fi
done
cp -a "${backup_files[@]}" "${BACKUP_DIR_PATH}"
7z a "$BACKUP_FILE_PATH" "$BACKUP_DIR_PATH"

echo "$BACKUP_DIR_PATH"
rm -rf "$BACKUP_DIR_PATH"

if [[ -n ${AGE_PUB} ]]; then
    age -r "$AGE_PUB" -o "$BACKUP_FILE_PATH.age" "$BACKUP_FILE_PATH"
    rm -rf "$BACKUP_FILE_PATH"
    BACKUP_FILE_PATH+=".age"
fi

# Attempt uploading to all remotes, even if some fail.
set +e

for dest in "${RCLONE_DESTS[@]}"; do
    rclone -vv sync "$(dirname "$BACKUP_FILE_PATH")" "${dest}"
done

# Purge old backups
find "$(dirname "$BACKUP_FILE_PATH")" -name 'vaultwarden-*.7z' -mtime +60 -delete
find "$(dirname "$BACKUP_FILE_PATH")" -name 'vaultwarden-*.age' -mtime +60 -delete
