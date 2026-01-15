#!/usr/bin/env bash
set -Eeuo pipefail

SERVERPACK_DIR="/serverpack"
SERVER_DIR="/server"
INSTALLED_FILE="$SERVER_DIR/.installed"

# Only runtime-controlled knobs
MEMORY="${MEMORY:-}"
EULA="${EULA:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
error() { log "ERROR: $*" >&2; }

cd "$SERVER_DIR"

TMP_BASE="/tmp/serverpack"
TMP_EXTRACT="$TMP_BASE/extract"
TMP_PRESERVE="$TMP_BASE/preserve"

cleanup() {
    rm -rf "$TMP_BASE"
}
trap cleanup EXIT

shutdown() {
    log "Shutting down server gracefully..."
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    exit 0
}
trap shutdown SIGTERM SIGINT

extract_version() {
    echo "$1" | grep -oP '\d+\.\d+\.\d+\.\d+' \
    || echo "$1" | grep -oP '\d+\.\d+\.\d+' \
    || echo "0.0.0"
}

get_latest_zip() {
    local best="" best_ver="0.0.0"
    shopt -s nullglob
    for f in "$SERVERPACK_DIR"/*.zip; do
        [[ "$f" == *backup* ]] && continue
        local v
        v=$(extract_version "$(basename "$f")")
        if [[ "$(printf '%s\n' "$best_ver" "$v" | sort -V | tail -n1)" == "$v" ]]; then
            best="$f"
            best_ver="$v"
        fi
    done
    echo "$best"
}

get_latest_backup() {
    shopt -s nullglob
    local backups=( "$SERVERPACK_DIR"/*-backup*.zip )
    [[ ${#backups[@]} -gt 0 ]] || return 1
    printf '%s\n' "${backups[@]}" | sort -r | head -n1
}

unzip_pack() {
    local zip="$1"
    rm -rf "$TMP_EXTRACT"
    mkdir -p "$TMP_EXTRACT"
    unzip -q -o "$zip" -d "$TMP_EXTRACT"

    local folder
    folder=$(find "$TMP_EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n1)

    if [[ -z "$folder" ]]; then
        error "Zip does not contain a folder"
        exit 1
    fi

    echo "$folder"
}

copy_into_server() {
    local src="$1"
    cp -rf "$src"/* "$SERVER_DIR"/
    cp -rf "$src"/.[!.]* "$SERVER_DIR"/ 2>/dev/null || true
}

preserve_files() {
    rm -rf "$TMP_PRESERVE"
    mkdir -p "$TMP_PRESERVE"
    local files=( world server.properties whitelist.json ops.json banned-players.json banned-ips.json eula.txt )

    for f in "${files[@]}"; do
        [[ -e "$SERVER_DIR/$f" ]] && cp -r "$SERVER_DIR/$f" "$TMP_PRESERVE/"
    done
}

restore_preserved() {
    shopt -s nullglob
    for f in "$TMP_PRESERVE"/*; do
        cp -rf "$f" "$SERVER_DIR/"
    done
}

load_pack_variables() {
    local vars_file="$SERVER_DIR/variables.txt"

    if [[ ! -f "$vars_file" ]]; then
        error "variables.txt not found in server pack!"
        exit 1
    fi

    log "Loading server pack variables from variables.txt"

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue

        # Strip surrounding quotes
        value="${value%\"}"
        value="${value#\"}"

        export "$key=$value"
    done < <(grep -v '^[[:space:]]*#' "$vars_file" | grep -v '^[[:space:]]*$')
}

CURRENT_VERSION=""
[[ -f "$INSTALLED_FILE" ]] && CURRENT_VERSION=$(cat "$INSTALLED_FILE")

BACKUP_ZIP=""
BACKUP_ZIP=$(get_latest_backup 2>/dev/null || true)

if [[ -n "$BACKUP_ZIP" ]]; then
    log "========================================="
    log "BACKUP RESTORE DETECTED"
    log "Found backup: $(basename "$BACKUP_ZIP")"
    log "========================================="

    rm -rf "$SERVER_DIR"/*
    rm -rf "$SERVER_DIR"/.[!.]*

    folder=$(unzip_pack "$BACKUP_ZIP")
    VERSION=$(extract_version "$(basename "$folder")")

    copy_into_server "$folder"
    echo "$VERSION" > "$INSTALLED_FILE"

    log "Backup restored successfully (v$VERSION)"

else
    SERVERPACK_ZIP=$(get_latest_zip)
    [[ -n "$SERVERPACK_ZIP" ]] || { error "No server pack zip found"; exit 1; }

    ZIP_NAME=$(basename "$SERVERPACK_ZIP")
    NEW_VERSION=$(extract_version "$ZIP_NAME")

    if [[ -n "$CURRENT_VERSION" && "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
        log "Server v$CURRENT_VERSION ready, starting..."
    else
        if [[ -n "$CURRENT_VERSION" ]]; then
            if [[ "$(printf '%s\n' "$CURRENT_VERSION" "$NEW_VERSION" | sort -V | head -n1)" == "$CURRENT_VERSION" ]]; then
                log "========================================="
                log "UPGRADE: $CURRENT_VERSION -> $NEW_VERSION"
                log "========================================="

                BACKUP_NAME="homestead-backup-${CURRENT_VERSION}-$(date +%Y%m%d-%H%M%S).zip"
                zip -q -r "$SERVER_DIR/$BACKUP_NAME" . \
                    -x "*.log" "logs/*" "crash-reports/*" ".installed" "fabric-installer*.jar" "homestead-backup*.zip"

                preserve_files
            else
                log "WARNING: Downgrade attempt $CURRENT_VERSION -> $NEW_VERSION"
                log "Delete .installed to force reinstall"
                exit 1
            fi
        else
            log "========================================="
            log "FRESH INSTALL: $NEW_VERSION"
            log "========================================="
        fi

        folder=$(unzip_pack "$SERVERPACK_ZIP")
        copy_into_server "$folder"

        [[ -d "$TMP_PRESERVE" ]] && restore_preserved

        echo "$NEW_VERSION" > "$INSTALLED_FILE"
        log "Server files installed: v$NEW_VERSION"
    fi
fi

# Load pack variables AFTER files are present
load_pack_variables

# Override memory if provided
if [[ -n "$MEMORY" ]]; then
    log "Overriding memory to ${MEMORY}"
    JAVA_ARGS="-Xmx${MEMORY} -Xms${MEMORY}"
fi

# Install Fabric (pack-driven)
if [[ ! -f "fabric-server-launch.jar" ]]; then
    log "Installing Fabric ${FABRIC_INSTALLER_VERSION}..."
    FABRIC_INSTALLER="fabric-installer-${FABRIC_INSTALLER_VERSION}.jar"
    curl -sOJ "https://maven.fabricmc.net/net/fabricmc/fabric-installer/${FABRIC_INSTALLER_VERSION}/$FABRIC_INSTALLER"
    java -jar "$FABRIC_INSTALLER" server \
        -mcversion "$MINECRAFT_VERSION" \
        -loader "$MODLOADER_VERSION" \
        -downloadMinecraft
fi

# EULA handling
if [[ "$EULA" == "true" ]]; then
    echo "eula=true" > eula.txt
elif ! grep -q "eula=true" eula.txt 2>/dev/null; then
    error "EULA not accepted. Set EULA=true"
    exit 1
fi

# Validate memory
if [[ "$JAVA_ARGS" =~ -Xmx([0-9]+)G ]]; then
    (( BASH_REMATCH[1] >= 2 )) || { error "Minimum 2GB RAM required"; exit 1; }
fi

log "Starting Minecraft server..."
log "Java Args: $JAVA_ARGS"
log "Additional Args: ${ADDITIONAL_ARGS:-}"

java $JAVA_ARGS ${ADDITIONAL_ARGS:-} -jar fabric-server-launch.jar nogui &
SERVER_PID=$!

wait $SERVER_PID
EXIT_CODE=$?

(( EXIT_CODE == 0 )) || error "Server exited with code $EXIT_CODE"
exit $EXIT_CODE
