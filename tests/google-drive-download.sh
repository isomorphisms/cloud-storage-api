#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
fake_bin=$temporary/bin
mkdir -p "$fake_bin"
: "${GREASE:?set GREASE to the Grease executable under test}"
: "${GOOGLE_DRIVE_DOWNLOAD_STATE:?set GOOGLE_DRIVE_DOWNLOAD_STATE to the compiled helper}"

source_file=$temporary/source.bin
printf '%s' 'abcdefghijklmnopqrstuvwxyz' > "$source_file"
source_size=$(wc -c < "$source_file" | tr -d '[:space:]')
source_sha256=$(sha256sum "$source_file" | awk '{print $1}')
curl_log=$temporary/curl.argv
range_log=$temporary/ranges.log
range_counter=$temporary/range.counter
: > "$curl_log"
: > "$range_log"
printf '%s\n' 0 > "$range_counter"

cat > "$fake_bin/curl" <<'EOF_CURL'
#!/bin/sh
set -eu
: "${FAKE_SOURCE:?}"
: "${FAKE_CURL_LOG:?}"
: "${FAKE_RANGE_LOG:?}"
: "${FAKE_RANGE_COUNTER:?}"
if [ "${1:-}" = --version ]; then printf '%s\n' 'curl 8.5.0 fake'; exit 0; fi
{
    printf '%s\n' '=== curl ==='
    for argument in "$@"; do printf '%s\n' "$argument"; done
} >> "$FAKE_CURL_LOG"

config=
headers=
output=
range=
maximum=
url=
while [ "$#" -gt 0 ]; do
    case $1 in
        --config) config=$2; shift 2 ;;
        --dump-header) headers=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        --header)
            case $2 in Range:\ bytes=*) range=${2#Range: bytes=} ;; esac
            shift 2
            ;;
        --max-filesize) maximum=$2; shift 2 ;;
        --request) shift 2 ;;
        --fail|--silent|--show-error) shift ;;
        http*) url=$1; shift ;;
        *) shift ;;
    esac
done

case $url in
    *'/drive/v3/files/'*'?supportsAllDrives=true&fields='*)
        id=${FAKE_METADATA_ID:-FILE123}
        size=${FAKE_METADATA_SIZE:-$(wc -c < "$FAKE_SOURCE" | tr -d '[:space:]')}
        checksum=${FAKE_METADATA_SHA256:-$(sha256sum "$FAKE_SOURCE" | awk '{print $1}')}
        can_download=${FAKE_CAN_DOWNLOAD:-true}
        [ -n "$headers" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"
        printf '{"id":"%s","name":"takeout.zip","size":"%s","mimeType":"application/zip","modifiedTime":"2026-09-20T00:00:00.000Z","version":"7","sha256Checksum":"%s","capabilities":{"canDownload":%s}}\n' \
            "$id" "$size" "$checksum" "$can_download"
        ;;
    *'/drive/v3/files/'*'?alt=media&supportsAllDrives=true')
        [ -n "$range" ] && [ -n "$headers" ] && [ -n "$output" ] && [ -n "$maximum" ] || exit 90
        count=$(sed -n '1p' "$FAKE_RANGE_COUNTER")
        count=$((count + 1))
        printf '%s\n' "$count" > "$FAKE_RANGE_COUNTER"
        start=${range%-*}
        end=${range#*-}
        length=$((end - start + 1))
        printf '%s\t%s\t%s\n' "$start" "$end" "$length" >> "$FAKE_RANGE_LOG"

        if [ "${FAKE_FAIL_CALL:-0}" -eq "$count" ]; then
            printf 'HTTP/1.1 503 Service Unavailable\r\n\r\n' > "$headers"
            exit 22
        fi
        if [ "${FAKE_EXPIRE_ON_CALL:-0}" -eq "$count" ] &&
           grep -F 'TOKEN_INITIAL' "$config" >/dev/null 2>&1
        then
            printf 'HTTP/1.1 401 Unauthorized\r\n\r\n' > "$headers"
            exit 22
        fi

        response_length=$length
        if [ "${FAKE_SHORT_RESPONSE:-0}" = 1 ]; then response_length=$((length - 1)); fi
        if [ "${FAKE_LONG_RESPONSE:-0}" = 1 ]; then response_length=$((length + 1)); fi
        dd if="$FAKE_SOURCE" of="$output" bs=1 skip="$start" count="$response_length" status=none
        status=${FAKE_RANGE_STATUS:-206}
        if [ "$status" = 206 ]; then
            total=${FAKE_METADATA_SIZE:-$(wc -c < "$FAKE_SOURCE" | tr -d '[:space:]')}
            if [ "${FAKE_BAD_CONTENT_RANGE:-0}" = 1 ]; then
                content_range="bytes 0-0/$total"
            else
                content_range="bytes $start-$end/$total"
            fi
            printf 'HTTP/1.1 206 Partial Content\r\nContent-Range: %s\r\n\r\n' "$content_range" > "$headers"
        else
            printf 'HTTP/1.1 %s OK\r\n\r\n' "$status" > "$headers"
        fi
        ;;
    *) printf 'unexpected fake Drive URL: %s\n' "$url" >&2; exit 91 ;;
esac
EOF_CURL
chmod +x "$fake_bin/curl"

auth_log=$temporary/auth.log
: > "$auth_log"
cat > "$fake_bin/fake-google-drive-auth" <<'EOF_AUTH'
#!/bin/sh
set -eu
: "${FAKE_AUTH_LOG:?}"
[ "$1" = curl-config ]
[ "$#" -ge 3 ]
output=$3
token=TOKEN_INITIAL
if [ "${4:-}" = --force-refresh ]; then token=TOKEN_REFRESHED; fi
printf '%s\n' "${4:-normal}" >> "$FAKE_AUTH_LOG"
umask 077
printf 'header = "Authorization: Bearer %s"\n' "$token" > "$output"
EOF_AUTH
chmod +x "$fake_bin/fake-google-drive-auth"

client=$root/commands/google-drive-download.grease
reset_transport() {
    : > "$curl_log"
    : > "$range_log"
    printf '%s\n' 0 > "$range_counter"
}

run_download() {
    PATH=$fake_bin:$PATH \
    GOOGLE_ACCESS_TOKEN=EXPLICIT_TOKEN \
    FAKE_SOURCE=$source_file \
    FAKE_CURL_LOG=$curl_log \
    FAKE_RANGE_LOG=$range_log \
    FAKE_RANGE_COUNTER=$range_counter \
    FAKE_FAIL_CALL=${FAKE_FAIL_CALL:-0} \
    FAKE_EXPIRE_ON_CALL=${FAKE_EXPIRE_ON_CALL:-0} \
    FAKE_METADATA_ID=${FAKE_METADATA_ID:-} \
    FAKE_METADATA_SIZE=${FAKE_METADATA_SIZE:-} \
    FAKE_METADATA_SHA256=${FAKE_METADATA_SHA256:-} \
    FAKE_CAN_DOWNLOAD=${FAKE_CAN_DOWNLOAD:-} \
    FAKE_RANGE_STATUS=${FAKE_RANGE_STATUS:-} \
    FAKE_BAD_CONTENT_RANGE=${FAKE_BAD_CONTENT_RANGE:-0} \
    FAKE_SHORT_RESPONSE=${FAKE_SHORT_RESPONSE:-0} \
    FAKE_LONG_RESPONSE=${FAKE_LONG_RESPONSE:-0} \
    GOOGLE_DRIVE_DOWNLOAD_STATE=$GOOGLE_DRIVE_DOWNLOAD_STATE \
    GREASE=$GREASE \
        "$GREASE" "$client" "$@"
}

assert_no_token_argv() {
    if grep -E 'EXPLICIT_TOKEN|TOKEN_INITIAL|TOKEN_REFRESHED' "$curl_log" >/dev/null; then
        printf '%s\n' 'bearer token leaked into curl argv' >&2
        cat "$curl_log" >&2
        exit 1
    fi
}

success=$temporary/success/archive.zip
reset_transport
success_receipt=$(run_download FILE123 "$success" --create-parent --chunk-size 7 2>"$temporary/success.err")
[ "$(sha256sum "$success" | awk '{print $1}')" = "$source_sha256" ]
[ ! -e "$success.google-drive.partial" ]
grep -F 'status=complete' "$success.google-drive.state" >/dev/null
printf '%s\n' "$success_receipt" | jq -e --arg hash "$source_sha256" \
    '.status == "complete" and .local_sha256 == $hash and .file_id == "FILE123"' >/dev/null
[ "$(wc -l < "$range_log" | tr -d '[:space:]')" = 4 ]
assert_no_token_argv

reset_transport
second_receipt=$(run_download FILE123 "$success" --chunk-size 7)
[ ! -s "$range_log" ]
printf '%s\n' "$second_receipt" | jq -e '.status == "complete"' >/dev/null

conflict=$temporary/conflict.bin
printf '%s' unrelated > "$conflict"
if run_download FILE123 "$conflict" --chunk-size 7 >/dev/null 2>"$temporary/conflict.err"; then
    printf '%s\n' 'unrelated destination unexpectedly accepted' >&2
    exit 1
fi
grep -F 'destination exists without matching download state' "$temporary/conflict.err" >/dev/null

resume=$temporary/resume/archive.zip
reset_transport
if FAKE_FAIL_CALL=2 run_download FILE123 "$resume" --create-parent --chunk-size 7 \
    >/dev/null 2>"$temporary/interrupted.err"
then
    printf '%s\n' 'interrupted transfer unexpectedly succeeded' >&2
    exit 1
fi
[ -f "$resume.google-drive.partial" ]
[ "$("$GOOGLE_DRIVE_DOWNLOAD_STATE" size "$resume.google-drive.partial")" = 7 ]
grep -F 'bytes_complete=7' "$resume.google-drive.state" >/dev/null
reset_transport
run_download FILE123 "$resume" --chunk-size 7 >/dev/null
[ "$(sha256sum "$resume" | awk '{print $1}')" = "$source_sha256" ]

reconcile=$temporary/reconcile/archive.zip
reset_transport
if FAKE_FAIL_CALL=2 run_download FILE123 "$reconcile" --create-parent --chunk-size 7 >/dev/null 2>/dev/null; then exit 1; fi
printf '%s' UNCOMMITTED >> "$reconcile.google-drive.partial"
reset_transport
run_download FILE123 "$reconcile" --chunk-size 7 >/dev/null 2>"$temporary/reconcile.err"
grep -F 'reconcile=truncate-uncommitted-tail' "$temporary/reconcile.err" >/dev/null
[ "$(sha256sum "$reconcile" | awk '{print $1}')" = "$source_sha256" ]

short=$temporary/short-state/archive.zip
reset_transport
if FAKE_FAIL_CALL=2 run_download FILE123 "$short" --create-parent --chunk-size 7 >/dev/null 2>/dev/null; then exit 1; fi
"$GOOGLE_DRIVE_DOWNLOAD_STATE" truncate "$short.google-drive.partial" 3
if run_download FILE123 "$short" --chunk-size 7 >/dev/null 2>"$temporary/short-state.err"; then
    printf '%s\n' 'short partial file unexpectedly resumed' >&2
    exit 1
fi
grep -F 'partial file is shorter than its durable state' "$temporary/short-state.err" >/dev/null

changed=$temporary/changed/archive.zip
reset_transport
if FAKE_FAIL_CALL=2 run_download FILE123 "$changed" --create-parent --chunk-size 7 >/dev/null 2>/dev/null; then exit 1; fi
if FAKE_METADATA_SIZE=27 run_download FILE123 "$changed" --chunk-size 7 >/dev/null 2>"$temporary/changed.err"; then
    printf '%s\n' 'changed remote size unexpectedly resumed' >&2
    exit 1
fi
grep -F 'remote Drive object size changed' "$temporary/changed.err" >/dev/null

identity=$temporary/identity/archive.zip
reset_transport
if FAKE_FAIL_CALL=2 run_download FILE123 "$identity" --create-parent --chunk-size 7 >/dev/null 2>/dev/null; then exit 1; fi
if FAKE_METADATA_ID=FILE999 run_download FILE999 "$identity" --chunk-size 7 >/dev/null 2>"$temporary/identity.err"; then
    printf '%s\n' 'mismatched Drive identity unexpectedly resumed' >&2
    exit 1
fi
grep -F 'different Drive file ID' "$temporary/identity.err" >/dev/null

bad_checksum=$temporary/bad-checksum/archive.zip
reset_transport
if FAKE_METADATA_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    run_download FILE123 "$bad_checksum" --create-parent --chunk-size 7 \
    >/dev/null 2>"$temporary/checksum.err"
then
    printf '%s\n' 'checksum mismatch unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'checksum does not match Drive metadata' "$temporary/checksum.err" >/dev/null
[ -f "$bad_checksum.google-drive.partial" ]
[ ! -e "$bad_checksum" ]

failure_case() {
    case_name=$1
    expected=$2
    target=$temporary/$case_name/archive.zip
    reset_transport
    if (
        case $case_name in
            ignored-range) export FAKE_RANGE_STATUS=200 ;;
            wrong-content-range) export FAKE_BAD_CONTENT_RANGE=1 ;;
            short-response) export FAKE_SHORT_RESPONSE=1 ;;
            long-response) export FAKE_LONG_RESPONSE=1 ;;
            *) exit 97 ;;
        esac
        run_download FILE123 "$target" --create-parent --chunk-size 7
    ) >/dev/null 2>"$temporary/$case_name.err"
    then
        printf 'bad range case unexpectedly succeeded: %s\n' "$case_name" >&2
        exit 1
    fi
    grep -F "$expected" "$temporary/$case_name.err" >/dev/null
}

failure_case ignored-range 'expected HTTP 206'
failure_case wrong-content-range 'wrong Content-Range'
failure_case short-response 'response length'
failure_case long-response 'response length'

zero_source=$temporary/zero-source.bin
: > "$zero_source"
zero_sha=$(sha256sum "$zero_source" | awk '{print $1}')
zero_destination=$temporary/zero/empty.bin
reset_transport
FAKE_SOURCE=$zero_source \
FAKE_CURL_LOG=$curl_log FAKE_RANGE_LOG=$range_log FAKE_RANGE_COUNTER=$range_counter \
PATH=$fake_bin:$PATH GOOGLE_ACCESS_TOKEN=EXPLICIT_TOKEN \
GOOGLE_DRIVE_DOWNLOAD_STATE=$GOOGLE_DRIVE_DOWNLOAD_STATE GREASE=$GREASE \
    "$GREASE" "$client" FILE123 "$zero_destination" --create-parent --chunk-size 7 >/dev/null
[ -f "$zero_destination" ]
[ "$("$GOOGLE_DRIVE_DOWNLOAD_STATE" size "$zero_destination")" = 0 ]
[ "$(sha256sum "$zero_destination" | awk '{print $1}')" = "$zero_sha" ]
[ ! -s "$range_log" ]

credential=$temporary/fake.credentials
printf '%s\n' 'private=fake' > "$credential"
chmod 600 "$credential"
refresh_destination=$temporary/refresh/archive.zip
reset_transport
: > "$auth_log"
PATH=$fake_bin:$PATH \
GOOGLE_DRIVE_CREDENTIAL_FILE=$credential \
GOOGLE_DRIVE_AUTH=$fake_bin/fake-google-drive-auth \
FAKE_AUTH_LOG=$auth_log \
FAKE_EXPIRE_ON_CALL=2 \
FAKE_SOURCE=$source_file FAKE_CURL_LOG=$curl_log \
FAKE_RANGE_LOG=$range_log FAKE_RANGE_COUNTER=$range_counter \
GOOGLE_DRIVE_DOWNLOAD_STATE=$GOOGLE_DRIVE_DOWNLOAD_STATE GREASE=$GREASE \
    "$GREASE" "$client" FILE123 "$refresh_destination" --create-parent --chunk-size 7 >/dev/null
grep -F -- '--force-refresh' "$auth_log" >/dev/null
[ "$(sha256sum "$refresh_destination" | awk '{print $1}')" = "$source_sha256" ]
assert_no_token_argv

replay_partial=$temporary/replay.partial
replay_segment=$temporary/replay.segment
printf '%s' abc > "$replay_partial"
printf '%s' de > "$replay_segment"
if "$GOOGLE_DRIVE_DOWNLOAD_STATE" append "$replay_partial" "$replay_segment" 0 2 \
    >/dev/null 2>"$temporary/replay.err"
then
    printf '%s\n' 'duplicate/replayed segment unexpectedly appended' >&2
    exit 1
fi
grep -F 'does not match the next segment offset' "$temporary/replay.err" >/dev/null

sparse=$temporary/over-4g.bin
truncate -s 5368709121 "$sparse"
[ "$("$GOOGLE_DRIVE_DOWNLOAD_STATE" size "$sparse")" = 5368709121 ]
plan=$("$GOOGLE_DRIVE_DOWNLOAD_STATE" plan 7754047385 5368709120 67108864)
printf '%s\n' "$plan" | grep -F 'range'
printf '%s\n' "$plan" | grep -F '5368709120'

printf '%s\n' 'restartable Drive download corruption, resume, refresh, conflict, zero-byte, and >4 GiB contracts pass'
