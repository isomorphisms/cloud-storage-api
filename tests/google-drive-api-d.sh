#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
binary=${1:?usage: google-drive-api-d.sh BINARY}
temporary=$(mktemp -d)
server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
    rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

port_file=$temporary/port
log_file=$temporary/requests.ndjson
server_stderr=$temporary/server.stderr
: > "$log_file"
: > "$server_stderr"
node "$root/tests/google-drive-api-d-server.mjs" "$port_file" "$log_file" 2>"$server_stderr" &
server_pid=$!

attempt=0
while [ ! -s "$port_file" ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        printf '%s\n' 'fake Drive server exited before listening:' >&2
        cat "$server_stderr" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
        printf '%s\n' 'fake Drive server did not start' >&2
        cat "$server_stderr" >&2
        exit 1
    fi
    sleep 0.05
done
port=$(cat "$port_file")
base=http://127.0.0.1:$port


assert_log() {
    pattern=$1
    if ! grep -F -- "$pattern" "$log_file" >/dev/null; then
        printf 'missing request-log text: %s\n' "$pattern" >&2
        cat "$log_file" >&2
        exit 1
    fi
}

run_client() {
    GOOGLE_ACCESS_TOKEN=SECRET_TOKEN_VALUE \
    GOOGLE_DRIVE_RESOURCE_KEYS='FILE123/RESOURCEKEY' \
    GOOGLE_DRIVE_API_BASE_URL="$base/drive/v3/" \
    GOOGLE_DRIVE_UPLOAD_BASE_URL="$base/upload/drive/v3/" \
        "$binary" "$@"
}

printf '%s\n' 'stage: method surface' >&2
method_count=$(run_client methods | wc -l | tr -d '[:space:]')
[ "$method_count" = 64 ] || { printf 'expected 64 methods, got %s\n' "$method_count" >&2; exit 1; }

run_client surface > "$temporary/surface.tsv"
cmp "$root/commands/google-drive-v3-methods.tsv" "$temporary/surface.tsv"

printf '%s\n' 'stage: list request' >&2
list_output=$(run_client files.list \
    --query "q=name contains 'report'" \
    --query 'fields=nextPageToken,files(id,name)')
[ "$list_output" = '{"files":[],"nextPageToken":"NEXT123"}' ]
assert_log '"url":"/drive/v3/files?q=name%20contains%20%27report%27&fields=nextPageToken%2Cfiles%28id%2Cname%29"'
assert_log '"resource_keys":"FILE123/RESOURCEKEY"'

printf '%s\n' 'stage: JSON body request' >&2
body=$temporary/permission.json
printf '%s\n' '{"type":"user","role":"reader","emailAddress":"reader@example.test"}' > "$body"
permission_output=$(run_client permissions.create \
    --path fileId=FILE123 \
    --query supportsAllDrives=true \
    --body "$body")
[ "$permission_output" = '{"id":"PERM123"}' ]
assert_log '"method":"POST","url":"/drive/v3/files/FILE123/permissions?supportsAllDrives=true"'
assert_log '"body":"{\"type\":\"user\",\"role\":\"reader\",\"emailAddress\":\"reader@example.test\"}\\n"'

printf '%s\n' 'stage: request validation' >&2
if run_client files.get --query alt=media > /dev/null 2> "$temporary/missing-path.err"; then
    printf '%s\n' 'files.get accepted a missing fileId' >&2
    exit 1
fi
grep -F 'missing --path value for drive.files.get' "$temporary/missing-path.err" >/dev/null

if run_client files.list --body "$body" > /dev/null 2> "$temporary/no-body.err"; then
    printf '%s\n' 'files.list accepted a request body' >&2
    exit 1
fi
grep -F 'drive.files.list has no request body' "$temporary/no-body.err" >/dev/null

printf '%s\n' 'stage: fresh resumable upload' >&2
metadata=$temporary/metadata.json
media=$temporary/data.bin
session=$temporary/upload.session
printf '%s\n' '{"name":"upload.bin"}' > "$metadata"
printf '%s' '1234567890' > "$media"
upload_output=$(run_client files.create \
    --body "$metadata" \
    --media "$media" \
    --media-type application/octet-stream \
    --session-file "$session")
[ "$upload_output" = '{"id":"UPLOADED"}' ]
[ ! -e "$session" ] || { printf '%s\n' 'completed upload left session file behind' >&2; exit 1; }
assert_log '"content_range":"bytes 0-9/10"'
assert_log '"content_range":"bytes 4-9/10","body":"567890"'

printf '%s\n' 'stage: persisted resumable recovery' >&2
resume=$temporary/resume.session
cat > "$resume" <<EOF_SESSION
{"method":"drive.files.create","path":"files","media":"$media","media_type":"application/octet-stream","media_size":10,"session_uri":"$base/session/RESUME"}
EOF_SESSION
chmod 600 "$resume"
resume_output=$(run_client files.create \
    --body "$metadata" \
    --media "$media" \
    --media-type application/octet-stream \
    --session-file "$resume")
[ "$resume_output" = '{"id":"RESUMED"}' ]
[ ! -e "$resume" ] || { printf '%s\n' 'resumed upload left session file behind' >&2; exit 1; }
assert_log '"content_range":"bytes */10","body":""'

grep -F 'SECRET_TOKEN_VALUE' "$log_file" >/dev/null
printf '%s\n' 'google-drive-api D contract passes'
