#!/usr/bin/env bash
# Live stage-6/7 acceptance; private extracted content stays on the ephemeral runner.
set -euo pipefail

: "${DRIVE_CURL_CONFIG:?set DRIVE_CURL_CONFIG to a private curl config}"
: "${TAKEOUT_FILE_ID:?set TAKEOUT_FILE_ID}"
: "${TAKEOUT_SIZE:?set TAKEOUT_SIZE}"

zip_helper=${ZIP_CENTRAL_DIRECTORY:-"${RUNNER_TEMP:-/tmp}/zip-central-directory"}
temporary_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
work="$temporary_root/takeout-live-extract"
rm -rf "$work"
mkdir -p "$work"

cc -std=c99 -Wall -Wextra -Werror -O2 \
  commands/zip-central-directory.c \
  -o "$zip_helper"

fetch_range() {
  local start=$1
  local end=$2
  local length=$3
  local output=$4
  local headers="$output.headers"
  local status

  status="$(
    curl \
      --config "$DRIVE_CURL_CONFIG" \
      --silent \
      --show-error \
      --request GET \
      --header "Range: bytes=$start-$end" \
      --dump-header "$headers" \
      --max-filesize "$length" \
      --output "$output" \
      --write-out '%{http_code}' \
      "https://www.googleapis.com/drive/v3/files/$TAKEOUT_FILE_ID?alt=media&supportsAllDrives=true"
  )"

  test "$status" = 206
  tr -d '\r' < "$headers" |
    grep -Fxi "Content-Range: bytes $start-$end/$TAKEOUT_SIZE" >/dev/null
  test "$(wc -c < "$output" | tr -d '[:space:]')" = "$length"
}

tab="$(printf '\t')"

tail_spec="$("$zip_helper" tail "$TAKEOUT_SIZE")"
IFS="$tab" read -r tail_start tail_end tail_length <<EOF
$tail_spec
EOF
fetch_range "$tail_start" "$tail_end" "$tail_length" "$work/tail.bin"

eocd="$("$zip_helper" eocd "$TAKEOUT_SIZE" "$tail_start" "$work/tail.bin")"
IFS="$tab" read -r kind a b c d e <<EOF
$eocd
EOF

case "$kind" in
  classic)
    central_start=$a
    central_end=$b
    central_size=$c
    member_count=$d
    ;;
  zip64)
    zip64_start=$a
    zip64_end=$b
    zip64_length=$c
    locator_offset=$d
    fetch_range "$zip64_start" "$zip64_end" "$zip64_length" "$work/zip64-eocd.bin"
    values="$("$zip_helper" zip64-eocd \
      "$TAKEOUT_SIZE" "$zip64_start" "$locator_offset" "$work/zip64-eocd.bin")"
    IFS="$tab" read -r central_start central_end central_size member_count unused <<EOF
$values
EOF
    ;;
  *)
    printf 'unsupported ZIP end record kind: %s\n' "$kind" >&2
    exit 1
    ;;
esac

if test "$central_size" -eq 0; then
  : > "$work/central.bin"
else
  fetch_range "$central_start" "$central_end" "$central_size" "$work/central.bin"
fi

"$zip_helper" list \
  "$central_start" "$central_size" "$member_count" "$work/central.bin" \
  > "$work/members.ndjson"

jq -c '
  select(
    (.path == "conversations.json") or
    (.path | endswith("/conversations.json")) or
    (.path == "chat.html") or
    (.path | endswith("/chat.html")) or
    (.path == "user.json") or
    (.path | endswith("/user.json")) or
    (.path == "message_feedback.json") or
    (.path | endswith("/message_feedback.json")) or
    (.path == "shared_conversations.json") or
    (.path | endswith("/shared_conversations.json"))
  )
' "$work/members.ndjson" > "$work/core.ndjson"

core_count="$(wc -l < "$work/core.ndjson" | tr -d '[:space:]')"
test "$core_count" -gt 0

printf 'archive_zip64=%s\n' "$([ "$kind" = zip64 ] && echo true || echo false)"
printf 'archive_member_count=%s\n' "$member_count"
printf 'central_directory_size=%s\n' "$central_size"
printf 'selected_core_member_count=%s\n' "$core_count"
jq -c \
  '{path,compressed_size,uncompressed_size,compression_method,crc32,general_purpose_flags,local_header_offset}' \
  "$work/core.ndjson"

conversations_count="$(
  jq -s \
    '[.[] | select(.path == "conversations.json" or (.path | endswith("/conversations.json")))] | length' \
    "$work/core.ndjson"
)"
test "$conversations_count" -eq 1

jq -c \
  'select(.path == "conversations.json" or (.path | endswith("/conversations.json")))' \
  "$work/core.ndjson" > "$work/conversations-member.json"

printf '%s\n' \
  'PASS stage 6: live 7.75 GB Takeout central directory validated and core ChatGPT members inventoried with bounded Drive ranges only.'

member="$work/conversations-member.json"
offset="$(jq -r '.local_header_offset' "$member")"
compressed_size="$(jq -r '.compressed_size' "$member")"
expected_uncompressed="$(jq -r '.uncompressed_size' "$member")"
expected_method="$(jq -r '.compression_method' "$member")"
expected_flags="$(jq -r '.general_purpose_flags' "$member")"
expected_crc="$(jq -r '.crc32' "$member")"
expected_path="$(jq -r '.path' "$member")"

fixed_end=$((offset + 29))
fetch_range "$offset" "$fixed_end" 30 "$work/local-fixed.bin"

header_info="$(
  python3 - "$work/local-fixed.bin" <<'PY'
import struct
import sys

data = open(sys.argv[1], 'rb').read()
if len(data) != 30:
    raise SystemExit('local fixed header must be 30 bytes')
fields = struct.unpack('<IHHHHHIIIHH', data)
signature, version, flags, method, mtime, mdate, crc, compressed, uncompressed, name_length, extra_length = fields
if signature != 0x04034B50:
    raise SystemExit('local file header signature mismatch')
print(flags, method, name_length, extra_length)
PY
)"
read -r local_flags local_method name_length extra_length <<EOF
$header_info
EOF

test "$local_method" = "$expected_method"
test "$local_flags" = "$expected_flags"

header_length=$((30 + name_length + extra_length))
header_end=$((offset + header_length - 1))
fetch_range "$offset" "$header_end" "$header_length" "$work/local-header.bin"

actual_path="$(
  python3 - "$work/local-header.bin" "$name_length" <<'PY'
import sys

data = open(sys.argv[1], 'rb').read()
name_length = int(sys.argv[2])
sys.stdout.write(data[30:30 + name_length].decode('utf-8'))
PY
)"
test "$actual_path" = "$expected_path"

data_start=$((offset + header_length))
data_end=$((data_start + compressed_size - 1))
fetch_range "$data_start" "$data_end" "$compressed_size" "$work/conversations.compressed"

python3 - \
  "$work/conversations.compressed" \
  "$work/conversations.json" \
  "$expected_method" \
  "$expected_crc" \
  "$expected_uncompressed" <<'PY'
import binascii
import sys
import zlib

source, destination, method_text, expected_crc, expected_size_text = sys.argv[1:]
method = int(method_text)
expected_size = int(expected_size_text)
crc = 0
written = 0

with open(source, 'rb') as source_file, open(destination, 'wb') as destination_file:
    if method == 0:
        while True:
            chunk = source_file.read(1024 * 1024)
            if not chunk:
                break
            destination_file.write(chunk)
            crc = binascii.crc32(chunk, crc)
            written += len(chunk)
    elif method == 8:
        decompressor = zlib.decompressobj(-zlib.MAX_WBITS)
        while True:
            chunk = source_file.read(1024 * 1024)
            if not chunk:
                break
            plain = decompressor.decompress(chunk)
            if plain:
                destination_file.write(plain)
                crc = binascii.crc32(plain, crc)
                written += len(plain)
        plain = decompressor.flush()
        if plain:
            destination_file.write(plain)
            crc = binascii.crc32(plain, crc)
            written += len(plain)
    else:
        raise SystemExit('unsupported compression method')

actual_crc = f'{crc & 0xffffffff:08x}'
if written != expected_size:
    raise SystemExit(f'uncompressed size mismatch: {written} != {expected_size}')
if actual_crc.lower() != expected_crc.lower():
    raise SystemExit(f'CRC mismatch: {actual_crc} != {expected_crc}')

print(f'uncompressed_size={written}')
print(f'crc32={actual_crc}')
PY

jq -e 'type == "array"' "$work/conversations.json" >/dev/null
conversation_count="$(jq 'length' "$work/conversations.json")"
output_sha256="$(sha256sum "$work/conversations.json" | awk '{print $1}')"

printf 'member_path=%s\n' "$expected_path"
printf 'conversation_count=%s\n' "$conversation_count"
printf 'output_sha256=%s\n' "$output_sha256"
printf '%s\n' \
  'PASS stage 7: conversations.json remotely extracted by bounded member-range reads and verified by size, CRC32, JSON shape, and SHA-256.'
printf '%s\n' \
  'NOTE: extracted private content remained only in the ephemeral runner and was not published.'
