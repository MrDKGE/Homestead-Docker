#!/usr/bin/env bash
# shellcheck disable=SC2016 # Single-quoted lines intentionally generate fake scripts.
set -Eeuo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENTRYPOINT="$PROJECT_DIR/entrypoint.sh"
TEST_ROOT=$(mktemp -d)

cleanup_tests() {
    local status=$?
    if [[ $status -ne 0 ]]; then
        echo "Test artifacts retained at: $TEST_ROOT" >&2
    elif [[ "${KEEP_TEST_ROOT:-false}" == "true" ]]; then
        echo "Test artifacts retained at: $TEST_ROOT"
    else
        chmod -R u+w "$TEST_ROOT" 2>/dev/null || true
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup_tests EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "expected file: $1"
}

assert_no_path() {
    [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

assert_equals() {
    [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_contains() {
    grep -Fq "$2" "$1" || fail "expected '$1' to contain '$2'"
}

make_fake_runtime() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'printf "CURL %s\n" "$*" >> "$TEST_EVENT_LOG"' \
        'touch "$2"' \
        > "$bin_dir/fake-curl"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'if [[ "${1:-}" == "-jar" && "${2:-}" == fabric-installer-*.jar ]]; then' \
        '    printf "INSTALL %s\n" "$*" >> "$TEST_EVENT_LOG"' \
        '    touch fabric-server-launch.jar server.jar' \
        'else' \
        '    printf "START %s\n" "$*" >> "$TEST_EVENT_LOG"' \
        'fi' \
        > "$bin_dir/fake-java"

    chmod +x "$bin_dir/fake-curl" "$bin_dir/fake-java"
}

make_pack() {
    local output_dir="$1" version="$2" loader="$3" marker="$4" layout="${5:-wrapped}"
    local staging content
    staging="$TEST_ROOT/staging-$(basename "$(dirname "$output_dir")")-$version-$marker"
    content="$staging/Homestead$version"

    rm -rf "$staging"
    mkdir -p "$content"/{config,defaultconfigs,kubejs,mods,patchouli_books,scripts}
    printf '%s\n' "$marker" > "$content/mods/pack-marker.txt"
    printf '%s\n' "$marker" > "$content/config/pack-marker.txt"
    printf '%s\n' 'motd=pack-default' > "$content/server.properties"
    printf '%s\n' \
        'MINECRAFT_VERSION=1.20.1' \
        "MODLOADER_VERSION=$loader" \
        'FABRIC_INSTALLER_VERSION=1.1.1' \
        'JAVA_ARGS="-Xmx5G -Xms5G -XX:+UseG1GC"' \
        'ADDITIONAL_ARGS=-Dtest=true' \
        > "$content/variables.txt"
    chmod 0555 "$content/mods"

    mkdir -p "$output_dir"
    if [[ "$layout" == "flat" ]]; then
        (cd "$content" && zip -qr "$output_dir/Homestead$version.zip" .)
    else
        (cd "$staging" && zip -qr "$output_dir/Homestead$version.zip" "Homestead$version")
    fi
}

run_entrypoint() {
    local case_dir="$1"
    shift
    env \
        SERVERPACK_DIR="$case_dir/packs" \
        SERVER_DIR="$case_dir/server" \
        TMP_BASE="$case_dir/tmp" \
        JAVA_BIN="$case_dir/bin/fake-java" \
        CURL_BIN="$case_dir/bin/fake-curl" \
        TEST_EVENT_LOG="$case_dir/events.log" \
        MEMORY=3G \
        EULA=true \
        "$@" \
        "$ENTRYPOINT" >> "$case_dir/output.log" 2>&1
}

new_case() {
    local name="$1" case_dir
    case_dir="$TEST_ROOT/$name"
    mkdir -p "$case_dir"/{packs,server,bin}
    : > "$case_dir/events.log"
    : > "$case_dir/output.log"
    make_fake_runtime "$case_dir/bin"
    printf '%s\n' "$case_dir"
}

test_fresh_install_and_version_selection() {
    local case_dir
    case_dir=$(new_case fresh)
    make_pack "$case_dir/packs" 1.0.0 0.16.0 old
    make_pack "$case_dir/packs" 1.0.1 0.17.0 latest flat
    printf 'ignored' > "$case_dir/packs/server-pack.zip"

    run_entrypoint "$case_dir"

    assert_equals "$(cat "$case_dir/server/.installed")" "1.0.1"
    assert_equals "$(cat "$case_dir/server/mods/pack-marker.txt")" "latest"
    [[ -w "$case_dir/server/mods" ]] || fail "installed mods directory is not owner-writable"
    assert_equals "$(cat "$case_dir/server/.fabric-runtime")" "1.20.1|0.17.0|1.1.1"
    assert_contains "$case_dir/events.log" "INSTALL -jar fabric-installer-1.1.1.jar"
    assert_contains "$case_dir/events.log" "START -Xmx3G -Xms3G -XX:+UseG1GC"
    assert_file "$case_dir/server/eula.txt"

    run_entrypoint "$case_dir"
    assert_equals "$(grep -c '^INSTALL ' "$case_dir/events.log")" "1"
    assert_contains "$case_dir/output.log" "Server v1.0.1 ready"
}

test_upgrade_backup_restore_and_repeat_guard() {
    local case_dir backup backup_name
    case_dir=$(new_case upgrade)
    make_pack "$case_dir/packs" 1.0.0 0.16.0 old
    run_entrypoint "$case_dir"

    mkdir -p "$case_dir/server/world"
    printf 'valuable-world' > "$case_dir/server/world/save.txt"
    printf 'motd=custom' > "$case_dir/server/server.properties"
    printf 'stale' > "$case_dir/server/mods/stale.jar"
    printf 'stale' > "$case_dir/server/config/stale.cfg"
    printf 'stale' > "$case_dir/server/defaultconfigs/stale.cfg"
    printf 'stale' > "$case_dir/server/patchouli_books/stale.json"

    make_pack "$case_dir/packs" 1.1.0 0.18.4 new
    run_entrypoint "$case_dir"

    assert_equals "$(cat "$case_dir/server/.installed")" "1.1.0"
    assert_equals "$(cat "$case_dir/server/world/save.txt")" "valuable-world"
    assert_equals "$(cat "$case_dir/server/server.properties")" "motd=custom"
    assert_no_path "$case_dir/server/mods/stale.jar"
    assert_no_path "$case_dir/server/config/stale.cfg"
    assert_no_path "$case_dir/server/defaultconfigs/stale.cfg"
    assert_no_path "$case_dir/server/patchouli_books/stale.json"
    assert_equals "$(cat "$case_dir/server/mods/pack-marker.txt")" "new"
    assert_equals "$(cat "$case_dir/server/.fabric-runtime")" "1.20.1|0.18.4|1.1.1"
    assert_equals "$(grep -c '^INSTALL ' "$case_dir/events.log")" "2"

    backup=$(find "$case_dir/server/backups" -name '*-upgrade.zip' -type f | head -n1)
    assert_file "$backup"
    unzip -Z1 "$backup" | grep -Fxq 'world/save.txt' || fail "backup does not contain the world"
    if unzip -Z1 "$backup" | grep -Eq '^(libraries|versions)/|^server\.jar$|^fabric-server-launch\.jar$'; then
        fail "backup contains generated runtime files"
    fi

    backup_name=$(basename "$backup")
    cp "$backup" "$case_dir/packs/$backup_name"
    run_entrypoint "$case_dir" RESTORE_BACKUP="$backup_name"

    assert_equals "$(cat "$case_dir/server/.installed")" "1.0.0"
    assert_equals "$(cat "$case_dir/server/world/save.txt")" "valuable-world"
    assert_equals "$(cat "$case_dir/server/mods/pack-marker.txt")" "old"

    printf 'post-restore-progress' > "$case_dir/server/world/after-restore.txt"
    run_entrypoint "$case_dir" RESTORE_BACKUP="$backup_name"
    assert_equals "$(cat "$case_dir/server/world/after-restore.txt")" "post-restore-progress"
    assert_contains "$case_dir/output.log" "Backup already restored"

    run_entrypoint "$case_dir"
    assert_equals "$(cat "$case_dir/server/.installed")" "1.1.0"
    assert_equals "$(cat "$case_dir/server/world/after-restore.txt")" "post-restore-progress"
    assert_no_path "$case_dir/server/.last-restored-backup"
}

test_refresh_downgrade_and_corrupt_archive_guards() {
    local case_dir
    case_dir=$(new_case guards)
    make_pack "$case_dir/packs" 2.0.0 0.18.0 original
    run_entrypoint "$case_dir"

    printf 'stale' > "$case_dir/server/mods/stale.jar"
    make_pack "$case_dir/packs" 2.0.0 0.18.1 refreshed
    run_entrypoint "$case_dir"
    assert_equals "$(cat "$case_dir/server/mods/pack-marker.txt")" "refreshed"
    assert_no_path "$case_dir/server/mods/stale.jar"
    find "$case_dir/server/backups" -name '*-refresh.zip' -type f | grep -q . || fail "refresh backup missing"

    make_pack "$case_dir/packs" 2.0.0 0.18.2 refreshed-again
    run_entrypoint "$case_dir"
    assert_equals "$(cat "$case_dir/server/mods/pack-marker.txt")" "refreshed-again"
    assert_equals "$(find "$case_dir/server/backups" -name '*-refresh*.zip' -type f | wc -l | tr -d ' ')" "2"

    rm -f "$case_dir/packs/Homestead2.0.0.zip"
    make_pack "$case_dir/packs" 1.9.9 0.17.0 older
    if run_entrypoint "$case_dir"; then
        fail "downgrade unexpectedly succeeded"
    fi
    assert_equals "$(cat "$case_dir/server/.installed")" "2.0.0"
    assert_contains "$case_dir/output.log" "Downgrade blocked"

    rm -f "$case_dir/packs/Homestead1.9.9.zip"
    printf 'not-a-zip' > "$case_dir/packs/Homestead9.9.9.zip"
    if run_entrypoint "$case_dir"; then
        fail "corrupt archive unexpectedly succeeded"
    fi
    assert_equals "$(cat "$case_dir/server/mods/pack-marker.txt")" "refreshed-again"
    assert_contains "$case_dir/output.log" "Archive failed its integrity check"
}

test_invalid_memory_and_missing_pack() {
    local memory_case missing_case temp_case
    memory_case=$(new_case memory)
    make_pack "$memory_case/packs" 1.0.0 0.18.0 current
    if env \
        SERVERPACK_DIR="$memory_case/packs" \
        SERVER_DIR="$memory_case/server" \
        TMP_BASE="$memory_case/tmp" \
        JAVA_BIN="$memory_case/bin/fake-java" \
        CURL_BIN="$memory_case/bin/fake-curl" \
        TEST_EVENT_LOG="$memory_case/events.log" \
        MEMORY=1536M EULA=true \
        "$ENTRYPOINT" >> "$memory_case/output.log" 2>&1; then
        fail "undersized memory unexpectedly succeeded"
    fi
    assert_contains "$memory_case/output.log" "Minimum 2048MB RAM required"

    if env \
        SERVERPACK_DIR="$memory_case/packs" \
        SERVER_DIR="$memory_case/server" \
        TMP_BASE="$memory_case/tmp" \
        JAVA_BIN="$memory_case/bin/fake-java" \
        CURL_BIN="$memory_case/bin/fake-curl" \
        TEST_EVENT_LOG="$memory_case/events.log" \
        MEMORY=08G EULA=true \
        "$ENTRYPOINT" >> "$memory_case/output.log" 2>&1; then
        fail "leading-zero memory unexpectedly succeeded"
    fi
    assert_contains "$memory_case/output.log" "MEMORY must use a whole-number"

    temp_case=$(new_case unsafe-temp)
    if env \
        SERVERPACK_DIR="$temp_case/packs" \
        SERVER_DIR="$temp_case/server" \
        TMP_BASE=/ \
        JAVA_BIN="$temp_case/bin/fake-java" \
        CURL_BIN="$temp_case/bin/fake-curl" \
        TEST_EVENT_LOG="$temp_case/events.log" \
        EULA=true \
        "$ENTRYPOINT" >> "$temp_case/output.log" 2>&1; then
        fail "root temporary directory unexpectedly succeeded"
    fi
    assert_contains "$temp_case/output.log" "TMP_BASE must be a non-root directory"

    missing_case=$(new_case missing)
    if run_entrypoint "$missing_case"; then
        fail "missing pack unexpectedly succeeded"
    fi
    assert_contains "$missing_case/output.log" "No versioned server pack ZIP found"
}

test_fresh_install_and_version_selection
test_upgrade_backup_restore_and_repeat_guard
test_refresh_downgrade_and_corrupt_archive_guards
test_invalid_memory_and_missing_pack

echo "All entrypoint tests passed"
