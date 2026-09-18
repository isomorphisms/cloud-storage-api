#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
fake_bin=$temporary/bin
mkdir -p "$fake_bin"

: "${GREASE:?set GREASE to the Grease executable under test}"
: "${ZIP_CENTRAL_DIRECTORY:?set ZIP_CENTRAL_DIRECTORY to the compiled helper}"

python=${PYTHON_FOR_FIXTURE:-python3}
"$python" - "$temporary/archive.zip" <<'PY'
from __future__ import print_function
import sys, zipfile
path=sys.argv[1]
z=zipfile.ZipFile(path,'w',allowZip64=False)
def add(name,data,method):
    info=zipfile.ZipInfo(name,(2026,1,1,0,0,0))
    info.compress_type=method
    z.writestr(info,data)
add('Takeout/My Activity/Search/MyActivity.json','{"search":1}\n',zipfile.ZIP_DEFLATED)
add('Takeout/Chrome/History.json','{"history":1}\n',zipfile.ZIP_DEFLATED)
add('notes/readme.txt','fixture\n',zipfile.ZIP_STORED)
add('padding.bin','x' * 200000,zipfile.ZIP_STORED)
z.close()
PY
archive=$temporary/archive.zip
archive_size=$(wc -c < "$archive" | tr -d '[:space:]')
range_log=$temporary/ranges.log
argv_log=$temporary/curl-argv.log
: > "$range_log"
: > "$argv_log"

cat > "$fake_bin/curl" <<'EOF_CURL'
#!/bin/sh
set -eu
: "${FAKE_ZIP:?}"
: "${FAKE_ZIP_SIZE:?}"
: "${FAKE_RANGE_LOG:?}"
: "${FAKE_ARGV_LOG:?}"

if [ "${1:-}" = --version ]; then
    printf 'curl %s fake\n' "${FAKE_CURL_VERSION:-8.5.0}"
    exit 0
fi

{
    printf '%s\n' '=== curl ==='
    for argument in "$@"; do printf '%s\n' "$argument"; done
} >> "$FAKE_ARGV_LOG"

output=
headers=
range=
max_size=
url=
while [ "$#" -gt 0 ]; do
    case $1 in
        --output) output=$2; shift 2 ;;
        --dump-header) headers=$2; shift 2 ;;
        --header)
            case $2 in
                Range:\ bytes=*) range=${2#Range: bytes=} ;;
            esac
            shift 2
            ;;
        --max-filesize) max_size=$2; shift 2 ;;
        --config|--request) shift 2 ;;
        --fail|--silent|--show-error) shift ;;
        http*) url=$1; shift ;;
        *) shift ;;
    esac
done

case $url in
    *'/drive/v3/files/ZIP123?'*'fields='*)
        printf '{"id":"ZIP123","name":"takeout.zip","size":"%s","sha256Checksum":"FIXTURESHA","mimeType":"application/zip","capabilities":{"canDownload":%s}}\n' "$FAKE_ZIP_SIZE" "${FAKE_CAN_DOWNLOAD:-true}"
        ;;
    *'/drive/v3/files/ZIP123?alt=media&supportsAllDrives=true')
        [ -n "$range" ] || {
            printf '%s\n' 'unbounded alt=media request rejected by fake transport' >&2
            exit 90
        }
        start=${range%-*}
        end=${range#*-}
        length=$((end - start + 1))
        [ -n "$max_size" ] && [ "$length" -le "$max_size" ]
        dd if="$FAKE_ZIP" of="$output" bs=1 skip="$start" count="$length" status=none
        printf '%s\n' "$length" >> "$FAKE_RANGE_LOG"
        status=${FAKE_RANGE_STATUS:-206}
        if [ "$status" = 206 ]; then
            {
                printf 'HTTP/1.1 206 Partial Content\r\n'
                if [ "${FAKE_BAD_CONTENT_RANGE:-0}" = 1 ]; then
                    printf 'Content-Range: bytes 0-0/%s\r\n' "$FAKE_ZIP_SIZE"
                else
                    printf 'Content-Range: bytes %s-%s/%s\r\n' "$start" "$end" "$FAKE_ZIP_SIZE"
                fi
                printf '\r\n'
            } > "$headers"
        else
            printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"
        fi
        ;;
    *)
        printf 'unexpected fake Drive request: %s\n' "$url" >&2
        exit 91
        ;;
esac
EOF_CURL
chmod +x "$fake_bin/curl"

client=$root/commands/google-drive-zip-inventory.grease
output=$temporary/inventory.ndjson
PATH=$fake_bin:$PATH \
GOOGLE_ACCESS_TOKEN=SECRET_TOKEN_VALUE \
FAKE_ZIP=$archive \
FAKE_ZIP_SIZE=$archive_size \
FAKE_RANGE_LOG=$range_log \
FAKE_ARGV_LOG=$argv_log \
ZIP_CENTRAL_DIRECTORY=$ZIP_CENTRAL_DIRECTORY \
GREASE=$GREASE \
    "$GREASE" "$client" ZIP123 --prefix 'Takeout/' > "$output"

head -n 1 "$output" | grep -F '"kind":"archive"' >/dev/null
head -n 1 "$output" | grep -F '"file_id":"ZIP123"' >/dev/null
[ "$(grep -c '"kind":"member"' "$output")" = 2 ]
grep -F '"path":"Takeout/My Activity/Search/MyActivity.json"' "$output" >/dev/null
grep -F '"path":"Takeout/Chrome/History.json"' "$output" >/dev/null
if grep -F 'SECRET_TOKEN_VALUE' "$argv_log" >/dev/null; then
    printf '%s\n' 'bearer token leaked into curl argv' >&2
    exit 1
fi
[ "$(wc -l < "$range_log" | tr -d '[:space:]')" = 2 ]
fetched=$(awk '{ total += $1 } END { print total + 0 }' "$range_log")
[ "$fetched" -lt "$archive_size" ] || {
    printf 'bounded inventory fetched %s bytes from %s-byte archive\n' "$fetched" "$archive_size" >&2
    exit 1
}

if PATH=$fake_bin:$PATH \
   GOOGLE_ACCESS_TOKEN=SECRET_TOKEN_VALUE \
   FAKE_ZIP=$archive FAKE_ZIP_SIZE=$archive_size \
   FAKE_RANGE_LOG=$range_log FAKE_ARGV_LOG=$argv_log \
   FAKE_RANGE_STATUS=200 \
   ZIP_CENTRAL_DIRECTORY=$ZIP_CENTRAL_DIRECTORY GREASE=$GREASE \
       "$GREASE" "$client" ZIP123 >/dev/null 2>"$temporary/status.err"
then
    printf '%s\n' 'HTTP 200 range response unexpectedly accepted' >&2
    exit 1
fi
grep -F 'did not return HTTP 206' "$temporary/status.err" >/dev/null

if PATH=$fake_bin:$PATH \
   GOOGLE_ACCESS_TOKEN=SECRET_TOKEN_VALUE \
   FAKE_ZIP=$archive FAKE_ZIP_SIZE=$archive_size \
   FAKE_RANGE_LOG=$range_log FAKE_ARGV_LOG=$argv_log \
   FAKE_BAD_CONTENT_RANGE=1 \
   ZIP_CENTRAL_DIRECTORY=$ZIP_CENTRAL_DIRECTORY GREASE=$GREASE \
       "$GREASE" "$client" ZIP123 >/dev/null 2>"$temporary/content-range.err"
then
    printf '%s\n' 'wrong Content-Range unexpectedly accepted' >&2
    exit 1
fi
grep -F 'did not confirm exactly bytes' "$temporary/content-range.err" >/dev/null

if PATH=$fake_bin:$PATH \
   GOOGLE_ACCESS_TOKEN=SECRET_TOKEN_VALUE \
   FAKE_ZIP=$archive FAKE_ZIP_SIZE=$archive_size \
   FAKE_RANGE_LOG=$range_log FAKE_ARGV_LOG=$argv_log \
   FAKE_CURL_VERSION=8.3.0 \
   ZIP_CENTRAL_DIRECTORY=$ZIP_CENTRAL_DIRECTORY GREASE=$GREASE \
       "$GREASE" "$client" ZIP123 >/dev/null 2>"$temporary/curl-version.err"
then
    printf '%s\n' 'old curl unexpectedly accepted for bounded inventory' >&2
    exit 1
fi
grep -F 'needs curl 8.4 or newer' "$temporary/curl-version.err" >/dev/null

if PATH=$fake_bin:$PATH \
   GOOGLE_ACCESS_TOKEN=SECRET_TOKEN_VALUE \
   FAKE_ZIP=$archive FAKE_ZIP_SIZE=$archive_size \
   FAKE_RANGE_LOG=$range_log FAKE_ARGV_LOG=$argv_log \
   FAKE_CAN_DOWNLOAD=false \
   ZIP_CENTRAL_DIRECTORY=$ZIP_CENTRAL_DIRECTORY GREASE=$GREASE \
       "$GREASE" "$client" ZIP123 >/dev/null 2>"$temporary/can-download.err"
then
    printf '%s\n' 'canDownload=false unexpectedly accepted' >&2
    exit 1
fi
grep -F 'cannot be downloaded' "$temporary/can-download.err" >/dev/null

printf 'archive_size=%s fetched=%s\n' "$archive_size" "$fetched"
printf '%s\n' 'fake Drive bounded-range inventory passes under Grease'
