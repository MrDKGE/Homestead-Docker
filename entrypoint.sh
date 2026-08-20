#!/usr/bin/env bash
set -Eeuo pipefail

SERVERPACK_DIR="${SERVERPACK_DIR:-/serverpack}"
SERVER_DIR="${SERVER_DIR:-/server}"
TMP_BASE="${TMP_BASE:-/tmp/serverpack}"
INSTALLED_FILE="$SERVER_DIR/.installed"
INSTALLED_ARCHIVE_FILE="$SERVER_DIR/.installed-archive"
FABRIC_RUNTIME_FILE="$SERVER_DIR/.fabric-runtime"
RESTORE_MARKER_FILE="$SERVER_DIR/.last-restored-backup"
BACKUP_DIR="$SERVER_DIR/backups"

MEMORY_OVERRIDE="${MEMORY:-}"
EULA="${EULA:-false}"
RESTORE_BACKUP="${RESTORE_BACKUP:-}"
JAVA_BIN="${JAVA_BIN:-java}"
CURL_BIN="${CURL_BIN:-curl}"

TMP_EXTRACT="$TMP_BASE/extract"
TMP_PRESERVE="$TMP_BASE/preserve"
SERVER_PID=""

PRESERVED_PATHS=(
    server.properties
    whitelist.json
    ops.json
    banned-players.json
    banned-ips.json
    eula.txt
)

# The real server packs contain these managed directories; replace them rather than merge them.
PACK_MANAGED_DIRS=(config defaultconfigs kubejs mods patchouli_books scripts)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
error() { log "ERROR: $*" >&2; }

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
    if [[ -n "$TMP_BASE" && "$TMP_BASE" != "/" ]]; then
        rm -rf "$TMP_BASE"
    fi
}
trap cleanup EXIT

# shellcheck disable=SC2329 # Invoked by signal traps.
shutdown() {
    log "Shutting down server gracefully..."
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    SERVER_PID=""
    exit 0
}
trap shutdown SIGTERM SIGINT

extract_version() {
    local input="$1" version

    version=$(printf '%s\n' "$input" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    if [[ -z "$version" ]]; then
        version=$(printf '%s\n' "$input" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    fi

    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

get_latest_zip() {
    local best="" best_version="" file version

    shopt -s nullglob
    for file in "$SERVERPACK_DIR"/*.zip; do
        [[ "$(basename "$file")" == *backup* ]] && continue

        if ! version=$(extract_version "$(basename "$file")"); then
            log "Ignoring server pack without a recognizable version: $(basename "$file")" >&2
            continue
        fi

        if [[ -z "$best" || "$(printf '%s\n' "$best_version" "$version" | sort -V | tail -n1)" == "$version" ]]; then
            best="$file"
            best_version="$version"
        fi
    done
    shopt -u nullglob

    printf '%s\n' "$best"
}

validate_archive() {
    local archive="$1" entry

    unzip -tq "$archive" >/dev/null || {
        error "Archive failed its integrity check: $(basename "$archive")"
        return 1
    }

    while IFS= read -r entry; do
        if [[ "$entry" == /* || "$entry" =~ (^|/)\.\.(/|$) ]]; then
            error "Archive contains an unsafe path: $entry"
            return 1
        fi
    done < <(zipinfo -1 "$archive")
}

unzip_pack() {
    local archive="$1"
    local entries=()

    if ! validate_archive "$archive"; then
        return 1
    fi
    rm -rf "$TMP_EXTRACT"
    mkdir -p "$TMP_EXTRACT"
    if ! unzip -q -o "$archive" -d "$TMP_EXTRACT"; then
        error "Could not extract archive: $(basename "$archive")"
        return 1
    fi

    shopt -s nullglob dotglob
    entries=("$TMP_EXTRACT"/*)
    shopt -u nullglob dotglob

    [[ ${#entries[@]} -gt 0 ]] || {
        error "Archive is empty: $(basename "$archive")"
        return 1
    }

    if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
        printf '%s\n' "${entries[0]}"
    else
        # Backups are intentionally flat archives; server packs with root files are valid too.
        printf '%s\n' "$TMP_EXTRACT"
    fi
}

copy_into_server() {
    local source_dir="$1"
    # Some official packs encode directories such as mods/ as read-only.
    # Normalize owner permissions in the extracted copy before installation.
    chmod -R u+rwX "$source_dir"
    cp -a "$source_dir"/. "$SERVER_DIR"/
}

preserve_files() {
    local path

    rm -rf "$TMP_PRESERVE"
    mkdir -p "$TMP_PRESERVE"
    for path in "${PRESERVED_PATHS[@]}"; do
        if [[ -e "$SERVER_DIR/$path" ]]; then
            cp -a "$SERVER_DIR/$path" "$TMP_PRESERVE/"
        fi
    done
}

restore_preserved() {
    if [[ -d "$TMP_PRESERVE" ]]; then
        cp -a "$TMP_PRESERVE"/. "$SERVER_DIR"/
    fi
}

remove_pack_managed_content() {
    local directory

    for directory in "${PACK_MANAGED_DIRS[@]}"; do
        rm -rf "${SERVER_DIR:?}/$directory"
    done
}

reset_fabric_runtime() {
    rm -rf \
        "$SERVER_DIR/.fabric-installer" \
        "$SERVER_DIR/libraries" \
        "$SERVER_DIR/versions"
    rm -f \
        "$SERVER_DIR"/fabric-installer-*.jar \
        "$SERVER_DIR/fabric-server-launch.jar" \
        "$SERVER_DIR/fabric-server-launcher.properties" \
        "$SERVER_DIR/server.jar" \
        "$FABRIC_RUNTIME_FILE"
}

create_backup() {
    local version="$1" reason="$2"
    local base_name name temp_archive final_archive counter=1

    mkdir -p "$BACKUP_DIR" "$TMP_BASE"
    base_name="homestead-backup-${version}-$(date +%Y%m%d-%H%M%S)-${reason}"
    name="${base_name}.zip"
    while [[ -e "$BACKUP_DIR/$name" ]]; do
        name="${base_name}-${counter}.zip"
        ((counter += 1))
    done
    temp_archive="$TMP_BASE/$name.partial"
    final_archive="$BACKUP_DIR/$name"

    log "Creating backup: $name"
    (
        cd "$SERVER_DIR"
        zip -q -r "$temp_archive" . \
            -x "*.log" "logs/*" "crash-reports/*" "backups/*" \
               ".installed" ".installed-archive" ".fabric-runtime" ".last-restored-backup" \
               ".fabric/*" ".mixin.out/*" \
               "fabric-installer-*.jar" "fabric-server-launch.jar" \
               "fabric-server-launcher.properties" "server.jar" \
               "libraries/*" "versions/*"
    )
    mv "$temp_archive" "$final_archive"
    log "Backup saved to: $final_archive"
}

clear_server_for_restore() {
    local path

    shopt -s nullglob dotglob
    for path in "$SERVER_DIR"/*; do
        [[ "$path" == "$BACKUP_DIR" ]] && continue
        rm -rf "$path"
    done
    shopt -u nullglob dotglob
}

load_pack_variables() {
    local variables_file="$SERVER_DIR/variables.txt"
    local key value

    [[ -f "$variables_file" ]] || {
        error "variables.txt not found in installed server pack"
        return 1
    }

    log "Loading server pack variables from variables.txt"
    while IFS='=' read -r key value; do
        key="${key%$'\r'}"
        value="${value%$'\r'}"
        [[ -z "$key" || "$key" == \#* ]] && continue

        value="${value%\"}"
        value="${value#\"}"

        case "$key" in
            MINECRAFT_VERSION|MODLOADER_VERSION|FABRIC_INSTALLER_VERSION|JAVA_ARGS|ADDITIONAL_ARGS)
                printf -v "$key" '%s' "$value"
                export "${key?}"
                ;;
        esac
    done < "$variables_file"

    local required
    for required in MINECRAFT_VERSION MODLOADER_VERSION FABRIC_INSTALLER_VERSION; do
        [[ -n "${!required:-}" ]] || {
            error "$required is missing from variables.txt"
            return 1
        }
    done
}

install_fabric_if_needed() {
    local desired_runtime installer
    desired_runtime="${MINECRAFT_VERSION}|${MODLOADER_VERSION}|${FABRIC_INSTALLER_VERSION}"

    if [[ -f "$FABRIC_RUNTIME_FILE" \
          && "$(cat "$FABRIC_RUNTIME_FILE")" == "$desired_runtime" \
          && -f "$SERVER_DIR/fabric-server-launch.jar" \
          && -f "$SERVER_DIR/server.jar" ]]; then
        log "Fabric runtime ready: Minecraft ${MINECRAFT_VERSION}, loader ${MODLOADER_VERSION}"
        return
    fi

    reset_fabric_runtime
    installer="fabric-installer-${FABRIC_INSTALLER_VERSION}.jar"
    log "Installing Fabric ${FABRIC_INSTALLER_VERSION} with loader ${MODLOADER_VERSION}..."
    "$CURL_BIN" -fSLo "$installer" \
        "https://maven.fabricmc.net/net/fabricmc/fabric-installer/${FABRIC_INSTALLER_VERSION}/${installer}"
    "$JAVA_BIN" -jar "$installer" server \
        -mcversion "$MINECRAFT_VERSION" \
        -loader "$MODLOADER_VERSION" \
        -downloadMinecraft

    [[ -f "$SERVER_DIR/fabric-server-launch.jar" && -f "$SERVER_DIR/server.jar" ]] || {
        error "Fabric installation completed without producing the required server jars"
        return 1
    }

    printf '%s\n' "$desired_runtime" > "$FABRIC_RUNTIME_FILE"
}

configure_java_args() {
    local configured_args="${JAVA_ARGS:-}"
    local argument memory_value memory_unit
    local parsed=() filtered=()

    read -r -a parsed <<< "$configured_args"
    if [[ -n "$MEMORY_OVERRIDE" ]]; then
        MEMORY_OVERRIDE=$(printf '%s' "$MEMORY_OVERRIDE" | tr '[:lower:]' '[:upper:]')
        [[ "$MEMORY_OVERRIDE" =~ ^([1-9][0-9]*)([MG])$ ]] || {
            error "MEMORY must use a whole-number M or G value, for example 8192M or 10G"
            return 1
        }
        memory_value="${BASH_REMATCH[1]}"
        memory_unit="${BASH_REMATCH[2]}"

        if [[ "$memory_unit" == "G" && "$memory_value" -lt 2 ]]; then
            error "Minimum 2GB RAM required"
            return 1
        fi
        if [[ "$memory_unit" == "M" && "$memory_value" -lt 2048 ]]; then
            error "Minimum 2048MB RAM required"
            return 1
        fi

        for argument in "${parsed[@]}"; do
            [[ "$argument" == -Xmx* || "$argument" == -Xms* ]] || filtered+=("$argument")
        done
        JAVA_ARG_ARRAY=("-Xmx${MEMORY_OVERRIDE}" "-Xms${MEMORY_OVERRIDE}" "${filtered[@]}")
        log "Overriding memory to ${MEMORY_OVERRIDE}"
    else
        JAVA_ARG_ARRAY=("${parsed[@]}")
    fi

    read -r -a ADDITIONAL_ARG_ARRAY <<< "${ADDITIONAL_ARGS:-}"
}

[[ -n "$SERVER_DIR" && "$SERVER_DIR" != "/" ]] || {
    error "SERVER_DIR must be a non-root directory"
    exit 1
}
[[ -n "$SERVERPACK_DIR" && "$SERVERPACK_DIR" != "/" ]] || {
    error "SERVERPACK_DIR must be a non-root directory"
    exit 1
}
[[ -n "$TMP_BASE" && "$TMP_BASE" != "/" ]] || {
    error "TMP_BASE must be a non-root directory"
    exit 1
}

mkdir -p "$SERVER_DIR" "$SERVERPACK_DIR" "$TMP_BASE"
cd "$SERVER_DIR"

CURRENT_VERSION=""
[[ -f "$INSTALLED_FILE" ]] && CURRENT_VERSION=$(head -n1 "$INSTALLED_FILE")

if [[ -n "$RESTORE_BACKUP" ]]; then
    [[ "$RESTORE_BACKUP" == "$(basename "$RESTORE_BACKUP")" ]] || {
        error "RESTORE_BACKUP must be a filename from the server-pack directory"
        exit 1
    }

    RESTORE_ARCHIVE="$SERVERPACK_DIR/$RESTORE_BACKUP"
    [[ -f "$RESTORE_ARCHIVE" ]] || {
        error "Requested backup not found: $RESTORE_BACKUP"
        exit 1
    }

    RESTORE_HASH=$(sha256sum "$RESTORE_ARCHIVE" | awk '{print $1}')
    if [[ -f "$RESTORE_MARKER_FILE" && "$(cat "$RESTORE_MARKER_FILE")" == "$RESTORE_HASH" ]]; then
        log "Backup already restored; unset RESTORE_BACKUP to resume pack updates"
    else
        # Fully validate and extract before changing the live server directory.
        if ! RESTORE_SOURCE=$(unzip_pack "$RESTORE_ARCHIVE"); then
            exit 1
        fi
        [[ -n "$CURRENT_VERSION" ]] && create_backup "$CURRENT_VERSION" "pre-restore"

        log "RESTORE: $RESTORE_BACKUP"
        clear_server_for_restore
        copy_into_server "$RESTORE_SOURCE"

        RESTORED_VERSION=$(extract_version "$RESTORE_BACKUP" || true)
        [[ -n "$RESTORED_VERSION" ]] || RESTORED_VERSION="unknown"
        printf '%s\n' "$RESTORED_VERSION" > "$INSTALLED_FILE"
        printf '%s\n' "$RESTORE_HASH" > "$RESTORE_MARKER_FILE"
        CURRENT_VERSION="$RESTORED_VERSION"
        log "Backup restored successfully (v$RESTORED_VERSION)"
    fi
else
    # Unsetting RESTORE_BACKUP explicitly re-enables this backup for a future restore.
    rm -f "$RESTORE_MARKER_FILE"

    SERVERPACK_ZIP=$(get_latest_zip)
    [[ -n "$SERVERPACK_ZIP" ]] || {
        error "No versioned server pack ZIP found in $SERVERPACK_DIR"
        exit 1
    }

    ZIP_NAME=$(basename "$SERVERPACK_ZIP")
    NEW_VERSION=$(extract_version "$ZIP_NAME")
    NEW_ARCHIVE_HASH=$(sha256sum "$SERVERPACK_ZIP" | awk '{print $1}')
    CURRENT_ARCHIVE_HASH=""
    [[ -f "$INSTALLED_ARCHIVE_FILE" ]] && CURRENT_ARCHIVE_HASH=$(cat "$INSTALLED_ARCHIVE_FILE")

    if [[ "$CURRENT_VERSION" == "$NEW_VERSION" && "$CURRENT_ARCHIVE_HASH" == "$NEW_ARCHIVE_HASH" ]]; then
        log "Server v$CURRENT_VERSION ready, starting..."
    else
        # Do not modify a working installation until the replacement is proven readable.
        if ! PACK_SOURCE=$(unzip_pack "$SERVERPACK_ZIP"); then
            exit 1
        fi
        UPDATE_REASON="fresh-install"
        if [[ -n "$CURRENT_VERSION" ]]; then
            if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
                UPDATE_REASON="refresh"
            elif [[ "$(printf '%s\n' "$CURRENT_VERSION" "$NEW_VERSION" | sort -V | head -n1)" == "$CURRENT_VERSION" ]]; then
                UPDATE_REASON="upgrade"
            else
                error "Downgrade blocked: $CURRENT_VERSION -> $NEW_VERSION"
                exit 1
            fi

            UPDATE_LABEL=$(printf '%s' "$UPDATE_REASON" | tr '[:lower:]' '[:upper:]')
            log "$UPDATE_LABEL: $CURRENT_VERSION -> $NEW_VERSION"
            create_backup "$CURRENT_VERSION" "$UPDATE_REASON"
            preserve_files
            remove_pack_managed_content
            reset_fabric_runtime
        else
            log "FRESH INSTALL: $NEW_VERSION"
        fi

        copy_into_server "$PACK_SOURCE"
        restore_preserved

        printf '%s\n' "$NEW_VERSION" > "$INSTALLED_FILE"
        printf '%s\n' "$NEW_ARCHIVE_HASH" > "$INSTALLED_ARCHIVE_FILE"
        CURRENT_VERSION="$NEW_VERSION"
        log "Server files installed: v$NEW_VERSION"
    fi
fi

load_pack_variables
configure_java_args
install_fabric_if_needed

if [[ "$EULA" == "true" ]]; then
    echo "eula=true" > "$SERVER_DIR/eula.txt"
elif ! grep -q '^eula=true$' "$SERVER_DIR/eula.txt" 2>/dev/null; then
    error "EULA not accepted. Set EULA=true"
    exit 1
fi

log "Starting Minecraft server..."
log "Java Args: ${JAVA_ARG_ARRAY[*]}"
log "Additional Args: ${ADDITIONAL_ARG_ARRAY[*]:-}"

"$JAVA_BIN" "${JAVA_ARG_ARRAY[@]}" "${ADDITIONAL_ARG_ARRAY[@]}" \
    -jar "$SERVER_DIR/fabric-server-launch.jar" nogui &
SERVER_PID=$!

if wait "$SERVER_PID"; then
    EXIT_CODE=0
else
    EXIT_CODE=$?
    error "Server exited with code $EXIT_CODE"
fi
SERVER_PID=""
exit "$EXIT_CODE"
