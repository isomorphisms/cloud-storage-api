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

{
    printf '%s\n' '=== curl call ==='
    for argument in "$@"; do
        printf '%s\n' "$argument"
    done
} >> "$FAKE_CURL_LOG"

headers_file=
output_file=
all_arguments=" $* "

while [ "$#" -gt 0 ]; do
    case $1 in
        --dump-header)
            headers_file=$2
            shift 2
            ;;
        --output)
            output_file=$2
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

case $all_arguments in
    *'uploadType=resumable'*)
        [ -n "$headers_file" ] || exit 91
        {
            printf 'HTTP/1.1 200 OK\r\n'
            printf 'Location: https://upload.example/session/ABC123\r\n'
            printf '\r\n'
        } > "$headers_file"
        ;;
    *'https://upload.example/session/ABC123'*)
        printf '%s\n' '{"id":"UPLOADED"}'
        ;;
    *'/permissions'*)
        printf '%s\n' '{"id":"PERM123"}'
        ;;
    *'/accessproposals/'*':resolve'*)
        printf '%s\n' '{"proposalId":"PROPOSAL123"}'
        ;;
    *)
        printf '%s\n' '{"files":[],"nextPageToken":"NEXT123"}'
        ;;
esac
EOF_CURL
chmod +x "$fake_bin/curl"

client=$root/commands/google-drive-api.grease
common_path=$fake_bin:$PATH

run_client() {
    PATH=$common_path \
    GOOGLE_ACCESS_TOKEN=SECRET_TOKEN_VALUE \
    FAKE_CURL_LOG=$log \
        "$GREASE" "$client" "$@"
}

assert_log() {
    pattern=$1
    grep -F -- "$pattern" "$log" >/dev/null || {
        printf 'missing curl argument: %s\n' "$pattern" >&2
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

method_count=$(run_client methods | wc -l | tr -d '[:space:]')
[ "$method_count" = 64 ] || {
    printf 'expected 64 pinned methods, got %s\n' "$method_count" >&2
    exit 1
}

list_output=$(
    run_client files.list \
        --query "q=name contains 'report'" \
        --query 'fields=nextPageToken,files(id,name,thumbnailLink,thumbnailVersion)'
)
[ "$list_output" = '{"files":[],"nextPageToken":"NEXT123"}' ] || {
    printf 'unexpected files.list result: %s\n' "$list_output" >&2
    exit 1
}
assert_log 'https://www.googleapis.com/drive/v3/files?q=name%20contains%20%27report%27&fields=nextPageToken%2Cfiles%28id%2Cname%2CthumbnailLink%2CthumbnailVersion%29'
assert_token_not_in_argv

body=$temporary/permission.json
printf '%s\n' '{"type":"user","role":"reader","emailAddress":"reader@example.test"}' > "$body"

permission_output=$(
    run_client permissions.create \
        --path fileId=FILE123 \
        --query supportsAllDrives=true \
        --body "$body"
)
[ "$permission_output" = '{"id":"PERM123"}' ] || {
    printf 'unexpected permissions.create result: %s\n' "$permission_output" >&2
    exit 1
}
assert_log 'POST'
assert_log 'https://www.googleapis.com/drive/v3/files/FILE123/permissions?supportsAllDrives=true'
assert_log "@$body"
assert_token_not_in_argv

proposal_output=$(
    run_client accessproposals.resolve \
        --path fileId=FILE123 \
        --path proposalId=PROPOSAL123 \
        --body "$body"
)
[ "$proposal_output" = '{"proposalId":"PROPOSAL123"}' ] || {
    printf 'unexpected accessproposals.resolve result: %s\n' "$proposal_output" >&2
    exit 1
}
assert_log 'https://www.googleapis.com/drive/v3/files/FILE123/accessproposals/PROPOSAL123:resolve'
assert_token_not_in_argv

printf '%s\n' '{"name":"upload.bin"}' > "$temporary/metadata.json"
media=$temporary/data.bin
printf '%s' '1234567890' > "$media"
session=$temporary/upload.session
upload_output=$(
    run_client files.create \
        --body "$temporary/metadata.json" \
        --media "$media" \
        --media-type application/octet-stream \
        --session-file "$session"
)
[ "$upload_output" = '{"id":"UPLOADED"}' ] || {
    printf 'unexpected resumable upload result: %s\n' "$upload_output" >&2
    exit 1
}
[ ! -e "$session" ] || {
    printf '%s\n' 'successful resumable upload left session record behind' >&2
    exit 1
}
assert_log 'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable'
assert_log 'https://upload.example/session/ABC123'
assert_log 'X-Upload-Content-Length: 10'
assert_token_not_in_argv

if run_client files.get --query alt=media >/dev/null 2>"$temporary/missing-path.err"; then
    printf '%s\n' 'files.get unexpectedly accepted a missing fileId path value' >&2
    exit 1
fi
grep -F 'missing --path value for drive.files.get' "$temporary/missing-path.err" >/dev/null

if run_client files.list --body "$body" >/dev/null 2>"$temporary/no-body.err"; then
    printf '%s\n' 'files.list unexpectedly accepted a request body' >&2
    exit 1
fi
grep -F 'has no request body' "$temporary/no-body.err" >/dev/null

printf '%s\n' 'google-drive-api Grease contract passes'
