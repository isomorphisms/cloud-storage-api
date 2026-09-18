#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
fake_bin=$temporary/bin
mkdir -p "$fake_bin"
: "${GREASE:?}"
: "${ZIP_CENTRAL_DIRECTORY:?}"
python=${PYTHON_FOR_FIXTURE:-python3}
"$python" - "$temporary" <<'PY'
from __future__ import print_function
import os, struct, sys, zipfile
root=sys.argv[1]
# classic
p=os.path.join(root,'classic.zip'); z=zipfile.ZipFile(p,'w',allowZip64=False)
def add(name,data,method):
    info=zipfile.ZipInfo(name,(2026,1,1,0,0,0)); info.compress_type=method; z.writestr(info,data)
add('Takeout/My Activity/Search/MyActivity.json','{"search":1}\n',zipfile.ZIP_DEFLATED)
add('Takeout/Chrome/History.json','{"history":1}\n',zipfile.ZIP_DEFLATED)
add('notes/readme.txt','fixture\n',zipfile.ZIP_STORED)
add('padding.bin','x'*200000,zipfile.ZIP_STORED); z.close()
# sparse ZIP64 at 5 GiB
p=os.path.join(root,'zip64.zip'); name=b'Takeout/big.bin'; cd=5*1024**3; size64=5*1024**3; crc=0x12345678
local=struct.pack('<IHHHHHIIIHH',0x04034b50,45,0,0,0,0,crc,0xffffffff,0xffffffff,len(name),20)
local_extra=struct.pack('<HHQQ',0x0001,16,size64,size64)
central_extra=struct.pack('<HHQQQ',0x0001,24,size64,size64,0)
central=struct.pack('<IHHHHHHIIIHHHHHII',0x02014b50,45,45,0,0,0,0,crc,0xffffffff,0xffffffff,len(name),len(central_extra),0,0,0,0,0xffffffff)+name+central_extra
z64=struct.pack('<IQHHIIQQQQ',0x06064b50,44,45,45,0,0,1,1,len(central),cd)
locator=struct.pack('<IIQI',0x07064b50,0,cd+len(central),1)
eocd=struct.pack('<IHHHHIIH',0x06054b50,0,0,1,1,len(central),0xffffffff,0)
with open(p,'wb') as f:
    f.write(local+name+local_extra); f.seek(cd); f.write(central+z64+locator+eocd)
PY
range_log=$temporary/ranges.log
argv_log=$temporary/curl-argv.log
: > "$range_log"; : > "$argv_log"
cat > "$fake_bin/curl" <<'EOF'
#!/bin/sh
set -eu
: "${FAKE_ZIP:?}"; : "${FAKE_ZIP_SIZE:?}"; : "${FAKE_RANGE_LOG:?}"; : "${FAKE_ARGV_LOG:?}"
if [ "${1:-}" = --version ]; then printf 'curl %s fake\n' "${FAKE_CURL_VERSION:-8.5.0}"; exit 0; fi
{ printf '%s\n' '=== curl ==='; for argument in "$@"; do printf '%s\n' "$argument"; done; } >> "$FAKE_ARGV_LOG"
output=; headers=; range=; max_size=; url=
while [ "$#" -gt 0 ]; do
 case $1 in
  --output) output=$2; shift 2;;
  --dump-header) headers=$2; shift 2;;
  --header) case $2 in Range:\ bytes=*) range=${2#Range: bytes=};; esac; shift 2;;
  --max-filesize) max_size=$2; shift 2;;
  --config|--request) shift 2;;
  --fail|--silent|--show-error) shift;;
  http*) url=$1; shift;;
  *) shift;;
 esac
done
case $url in
 *'/drive/v3/files/ZIP123?'*'fields='*) printf '{"id":"ZIP123","name":"takeout.zip","size":"%s","sha256Checksum":"FIXTURESHA","mimeType":"application/zip","capabilities":{"canDownload":%s}}\n' "$FAKE_ZIP_SIZE" "${FAKE_CAN_DOWNLOAD:-true}";;
 *'/drive/v3/files/ZIP123?alt=media&supportsAllDrives=true')
  [ -n "$range" ] || { echo unbounded >&2; exit 90; }
  start=${range%-*}; end=${range#*-}; length=$((end-start+1)); [ -n "$max_size" ] && [ "$length" -le "$max_size" ]
  dd if="$FAKE_ZIP" of="$output" bs=1 skip="$start" count="$length" status=none
  printf '%s\n' "$length" >> "$FAKE_RANGE_LOG"
  status=${FAKE_RANGE_STATUS:-206}
  if [ "$status" = 206 ]; then
   { printf 'HTTP/1.1 206 Partial Content\r\n'; if [ "${FAKE_BAD_CONTENT_RANGE:-0}" = 1 ]; then printf 'Content-Range: bytes 0-0/%s\r\n' "$FAKE_ZIP_SIZE"; else printf 'Content-Range: bytes %s-%s/%s\r\n' "$start" "$end" "$FAKE_ZIP_SIZE"; fi; printf '\r\n'; } > "$headers"
  else printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"; fi;;
 *) echo "unexpected fake Drive request: $url" >&2; exit 91;;
esac
EOF
chmod +x "$fake_bin/curl"
client=$root/commands/google-drive-zip-inventory.grease
run_one() {
 archive=$1; output=$2; prefix=$3
 size=$(wc -c < "$archive" | tr -d '[:space:]')
 : > "$range_log"; : > "$argv_log"
 PATH=$fake_bin:$PATH GOOGLE_ACCESS_TOKEN=SECRET_TOKEN_VALUE FAKE_ZIP=$archive FAKE_ZIP_SIZE=$size FAKE_RANGE_LOG=$range_log FAKE_ARGV_LOG=$argv_log ZIP_CENTRAL_DIRECTORY=$ZIP_CENTRAL_DIRECTORY GREASE=$GREASE "$GREASE" "$client" ZIP123 --prefix "$prefix" > "$output"
 if grep -F SECRET_TOKEN_VALUE "$argv_log" >/dev/null; then echo token-leak >&2; exit 1; fi
 fetched=$(awk '{total+=$1} END{print total+0}' "$range_log")
 [ "$fetched" -lt "$size" ]
}
run_one "$temporary/classic.zip" "$temporary/classic.ndjson" 'Takeout/'
grep -F '"zip64":false' "$temporary/classic.ndjson" >/dev/null
[ "$(grep -c '"kind":"member"' "$temporary/classic.ndjson")" = 2 ]
[ "$(wc -l < "$range_log" | tr -d '[:space:]')" = 2 ]
run_one "$temporary/zip64.zip" "$temporary/zip64.ndjson" 'Takeout/'
grep -F '"zip64":true' "$temporary/zip64.ndjson" >/dev/null
grep -F '"compressed_size":5368709120' "$temporary/zip64.ndjson" >/dev/null
[ "$(grep -c '"kind":"member"' "$temporary/zip64.ndjson")" = 1 ]
[ "$(wc -l < "$range_log" | tr -d '[:space:]')" = 3 ]
printf 'zip64_size=%s fetched=%s\n' "$(wc -c < "$temporary/zip64.zip" | tr -d '[:space:]')" "$fetched"
archive=$temporary/zip64.zip
archive_size=$(wc -c < "$archive" | tr -d '[:space:]')

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

printf '%s\n' 'fake Drive classic ZIP and ZIP64 bounded-range inventory passes under Grease'
