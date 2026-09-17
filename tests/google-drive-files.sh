#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
fake_bin=$temporary/bin
log=$temporary/curl-arguments.txt
mkdir -p "$fake_bin"
: > "$log"

: "${GREASE:?set GREASE to the Grease executable under test}"

cat > "$fake_bin/curl" <<'EOF_CURL'
#!/bin/sh
set -eu
: "${FAKE_CURL_LOG:?}"

for argument in "$@"; do
    printf '%s\n' "$argument" >> "$FAKE_CURL_LOG"
done

case " $* " in
    *'/export?'*)
        printf '%s' 'EXPORTED-BYTES'
        ;;
    *'alt=media'*)
        printf '%s' 'STORED-BYTES'
        ;;
    *'/files/FILE123?'*)
        printf '%s\n' '{"id":"FILE123","name":"report.txt"}'
        ;;
    *)
        printf '%s\n' '{"files":[],"nextPageToken":"NEXT123"}'
        ;;
esac
EOF_CURL
chmod +x "$fake_bin/curl"

client=$root/commands/google-drive-files.grease
common_path=$fake_bin:$PATH

run_client() {
    PATH=$common_path \
    GOOGLE_ACCESS_TOKEN=SECRET_TOKEN_VALUE \
    FAKE_CURL_LOG=$log \
    GREASE="$GREASE" \
        "$GREASE" "$client" "$@"
}

assert_log() {
    pattern=$1
    grep -F -- "$pattern" "$log" >/dev/null || {
        printf 'missing curl argument text: %s\n' "$pattern" >&2
        cat "$log" >&2
        exit 1
    }
}

assert_token_not_in_argv() {
    if grep -F 'SECRET_TOKEN_VALUE' "$log" >/dev/null; then
        printf '%s\n' 'bearer token leaked into curl argv' >&2
        cat "$log" >&2
        exit 1
    fi
}

list_output=$(
    run_client list \
        --query "name contains 'report'" \
        --page PAGE123 \
        --drive 'https://drive.google.com/drive/folders/DRIVE123?usp=sharing'
)
[ "$list_output" = '{"files":[],"nextPageToken":"NEXT123"}' ] || {
    printf 'unexpected list result: %s\n' "$list_output" >&2
    exit 1
}
assert_log 'https://www.googleapis.com/drive/v3/files?'
assert_log 'q=name%20contains%20%27report%27'
assert_log 'pageToken=PAGE123'
assert_log 'corpora=drive'
assert_log 'driveId=DRIVE123'
assert_log 'thumbnailLink'
assert_log 'thumbnailVersion'
assert_log 'hasThumbnail'
assert_token_not_in_argv

get_output=$(run_client get 'https://drive.google.com/file/d/FILE123/view?usp=sharing')
[ "$get_output" = '{"id":"FILE123","name":"report.txt"}' ] || {
    printf 'unexpected get result: %s\n' "$get_output" >&2
    exit 1
}
assert_log 'https://www.googleapis.com/drive/v3/files/FILE123?'
assert_log 'supportsAllDrives=true'
assert_log 'thumbnailLink'
assert_token_not_in_argv

download_output=$(run_client download BLOB123)
[ "$download_output" = 'STORED-BYTES' ] || {
    printf 'unexpected download result: %s\n' "$download_output" >&2
    exit 1
}
assert_log 'https://www.googleapis.com/drive/v3/files/BLOB123?alt=media'
assert_token_not_in_argv

export_output=$(run_client export 'https://drive.google.com/open?id=WORK123' application/pdf)
[ "$export_output" = 'EXPORTED-BYTES' ] || {
    printf 'unexpected export result: %s\n' "$export_output" >&2
    exit 1
}
assert_log 'https://www.googleapis.com/drive/v3/files/WORK123/export?mimeType=application%2Fpdf'
assert_token_not_in_argv

help=$("$GREASE" "$client" --help)
printf '%s\n' "$help" | grep -F 'google-drive-files list' >/dev/null
printf '%s\n' "$help" | grep -F 'thumbnailVersion' >/dev/null

printf '%s\n' 'google-drive-files Grease contract passes'
