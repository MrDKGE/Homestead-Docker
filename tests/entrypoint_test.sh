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
        'output=""' \
        'previous=""' \
        'for argument in "$@"; do' \
        '    if [[ "$previous" == "-o" || "$previous" == *o ]]; then output="$argument"; fi' \
        '    previous="$argument"' \
        'done' \
        'url="${*: -1}"' \
        'if [[ "$url" == "${AUTO_DOWNLOAD_TEST_INDEX_URL:-}" ]]; then' \
        '    [[ "${AUTO_DOWNLOAD_TEST_FAIL:-}" != "index" ]] || exit 22' \
        '    cp "$AUTO_DOWNLOAD_TEST_INDEX" "$output"' \
        'elif [[ "$url" == https://downloads.test/* ]]; then' \
        '    [[ "${AUTO_DOWNLOAD_TEST_FAIL:-}" != "download" ]] || exit 22' \
        '    version=$(printf "%s\n" "$url" | grep -oE "[0-9]+\\.[0-9]+\\.[0-9]+(\\.[0-9]+)?")' \
        '    cp "$AUTO_DOWNLOAD_TEST_PACK_DIR/Homestead$version.zip" "$output"' \
        'else' \
        '    touch "$output"' \
        'fi' \
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

make_download_index() {
    local output="$1"
    shift
    : > "$output"
    local version
    for version in "$@"; do
        printf '<a href="https://downloads.test/Homestead%s.zip">Download Homestead Server Pack %s</a>\n' \
            "$version" "$version" >> "$output"
    done
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

    backup=$(find "$case_dir/server/backups" -name '*-upgrade.zip' -type f -print -quit)
    assert_file "$backup"
    grep -Fxq 'world/save.txt' < <(unzip -Z1 "$backup") || fail "backup does not contain the world"
    if grep -Eq '^(libraries|versions)/|^server\.jar$|^fabric-server-launch\.jar$' < <(unzip -Z1 "$backup"); then
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
    [[ -n "$(find "$case_dir/server/backups" -name '*-refresh.zip' -type f -print -quit)" ]] || fail "refresh backup missing"

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

test_auto_download_fresh_exact_latest_and_cache() {
    local latest_case exact_case index source_dir

    latest_case=$(new_case auto-latest)
    source_dir="$latest_case/downloads"
    index="$latest_case/index.html"
    make_pack "$source_dir" 3.0.0 0.18.0 downloaded-latest
    make_download_index "$index" 2.9.0 3.0.0
    make_pack "$latest_case/packs" 1.0.0 0.16.0 stale-local
    chmod 0555 "$latest_case/packs"

    run_entrypoint "$latest_case" \
        VERSION=latest \
        AUTO_DOWNLOAD_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_INDEX="$index" \
        AUTO_DOWNLOAD_TEST_PACK_DIR="$source_dir"

    assert_equals "$(cat "$latest_case/server/.installed")" "3.0.0"
    assert_equals "$(cat "$latest_case/server/mods/pack-marker.txt")" "downloaded-latest"
    assert_file "$latest_case/server/.serverpack-cache/Homestead3.0.0_server_pack.zip"
    assert_equals "$(grep -c 'https://downloads.test/' "$latest_case/events.log")" "1"

    run_entrypoint "$latest_case" \
        VERSION=latest \
        AUTO_DOWNLOAD_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_INDEX="$index" \
        AUTO_DOWNLOAD_TEST_PACK_DIR="$source_dir"
    assert_equals "$(grep -c 'https://downloads.test/' "$latest_case/events.log")" "1"
    assert_contains "$latest_case/output.log" "Using cached Homestead server pack v3.0.0"

    exact_case=$(new_case auto-exact)
    source_dir="$exact_case/downloads"
    index="$exact_case/index.html"
    make_pack "$source_dir" 2.5.0 0.17.5 pinned
    make_pack "$exact_case/packs" 9.0.0 0.19.0 newer-local
    make_download_index "$index" 2.5.0 9.0.0

    run_entrypoint "$exact_case" \
        VERSION=2.5.0 \
        AUTO_DOWNLOAD_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_INDEX="$index" \
        AUTO_DOWNLOAD_TEST_PACK_DIR="$source_dir"
    assert_equals "$(cat "$exact_case/server/.installed")" "2.5.0"
    assert_equals "$(cat "$exact_case/server/mods/pack-marker.txt")" "pinned"

    run_entrypoint "$exact_case" \
        VERSION=2.5.0 AUTO_DOWNLOAD_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_FAIL=index
    assert_equals "$(cat "$exact_case/server/.installed")" "2.5.0"
    assert_contains "$exact_case/output.log" "Using cached Homestead server pack v2.5.0"
}

test_auto_download_update_failure_and_downgrade_guards() {
    local case_dir index source_dir
    case_dir=$(new_case auto-update)
    source_dir="$case_dir/downloads"
    index="$case_dir/index.html"
    make_pack "$source_dir" 4.0.0 0.18.0 initial
    make_download_index "$index" 4.0.0
    run_entrypoint "$case_dir" \
        VERSION=latest AUTO_DOWNLOAD_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_INDEX_URL=https://test.invalid/index AUTO_DOWNLOAD_TEST_INDEX="$index" \
        AUTO_DOWNLOAD_TEST_PACK_DIR="$source_dir"

    mkdir -p "$case_dir/server/world"
    printf 'world-data' > "$case_dir/server/world/save.txt"
    make_pack "$source_dir" 4.1.0 0.18.1 update
    make_download_index "$index" 4.1.0 4.0.0
    if run_entrypoint "$case_dir" \
        VERSION=latest AUTO_DOWNLOAD_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_INDEX_URL=https://test.invalid/index AUTO_DOWNLOAD_TEST_INDEX="$index" \
        AUTO_DOWNLOAD_TEST_PACK_DIR="$source_dir" AUTO_DOWNLOAD_TEST_FAIL=download; then
        fail "failed automatic download unexpectedly succeeded"
    fi
    assert_equals "$(cat "$case_dir/server/.installed")" "4.0.0"
    assert_equals "$(cat "$case_dir/server/world/save.txt")" "world-data"
    assert_no_path "$case_dir/server/.serverpack-cache/Homestead4.1.0_server_pack.zip.partial"

    run_entrypoint "$case_dir" \
        VERSION=latest AUTO_DOWNLOAD_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_INDEX_URL=https://test.invalid/index AUTO_DOWNLOAD_TEST_INDEX="$index" \
        AUTO_DOWNLOAD_TEST_PACK_DIR="$source_dir"
    assert_equals "$(cat "$case_dir/server/.installed")" "4.1.0"
    assert_equals "$(cat "$case_dir/server/world/save.txt")" "world-data"
    [[ -n "$(find "$case_dir/server/backups" -name '*-upgrade.zip' -type f -print -quit)" ]] || fail "automatic update backup missing"

    make_download_index "$index" 4.0.0
    if run_entrypoint "$case_dir" \
        VERSION=latest AUTO_DOWNLOAD_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_INDEX_URL=https://test.invalid/index AUTO_DOWNLOAD_TEST_INDEX="$index" \
        AUTO_DOWNLOAD_TEST_PACK_DIR="$source_dir"; then
        fail "automatic downgrade unexpectedly succeeded"
    fi
    assert_equals "$(cat "$case_dir/server/.installed")" "4.1.0"
    assert_contains "$case_dir/output.log" "Downgrade blocked"
}

test_auto_download_validation_and_restore_precedence() {
    local invalid_case corrupt_case restore_case backup backup_name index source_dir
    invalid_case=$(new_case auto-invalid)
    if run_entrypoint "$invalid_case" VERSION=current; then
        fail "invalid VERSION unexpectedly succeeded"
    fi
    assert_contains "$invalid_case/output.log" "VERSION must be 'latest'"

    corrupt_case=$(new_case auto-corrupt)
    source_dir="$corrupt_case/downloads"
    index="$corrupt_case/index.html"
    mkdir -p "$source_dir"
    printf 'not-a-zip' > "$source_dir/Homestead6.0.0.zip"
    make_download_index "$index" 6.0.0
    if run_entrypoint "$corrupt_case" \
        VERSION=latest AUTO_DOWNLOAD_INDEX_URL=https://test.invalid/index \
        AUTO_DOWNLOAD_TEST_INDEX_URL=https://test.invalid/index AUTO_DOWNLOAD_TEST_INDEX="$index" \
        AUTO_DOWNLOAD_TEST_PACK_DIR="$source_dir"; then
        fail "invalid automatic download unexpectedly succeeded"
    fi
    assert_contains "$corrupt_case/output.log" "Archive failed its integrity check"
    assert_no_path "$corrupt_case/server/.serverpack-cache/Homestead6.0.0_server_pack.zip"
    assert_no_path "$corrupt_case/server/.serverpack-cache/Homestead6.0.0_server_pack.zip.partial"

    restore_case=$(new_case auto-restore)
    make_pack "$restore_case/packs" 5.0.0 0.18.0 current
    run_entrypoint "$restore_case"
    mkdir -p "$restore_case/server/world"
    printf 'before-update' > "$restore_case/server/world/save.txt"
    make_pack "$restore_case/packs" 5.1.0 0.18.1 update
    run_entrypoint "$restore_case"
    backup=$(find "$restore_case/server/backups" -name '*-upgrade.zip' -type f -print -quit)
    backup_name=$(basename "$backup")
    cp "$backup" "$restore_case/packs/$backup_name"

    run_entrypoint "$restore_case" RESTORE_BACKUP="$backup_name" VERSION=latest \
        AUTO_DOWNLOAD_INDEX_URL=https://test.invalid/index AUTO_DOWNLOAD_TEST_FAIL=index
    assert_equals "$(cat "$restore_case/server/.installed")" "5.0.0"
    assert_equals "$(cat "$restore_case/server/world/save.txt")" "before-update"
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
test_auto_download_fresh_exact_latest_and_cache
test_auto_download_update_failure_and_downgrade_guards
test_auto_download_validation_and_restore_precedence
test_invalid_memory_and_missing_pack

echo "All entrypoint tests passed"
