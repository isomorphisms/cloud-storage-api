#!/usr/bin/env bash
set -euo pipefail

phase=start
trap 'status=$?; printf "FAIL: ChatGPT export discovery phase=%s line=%s status=%s\n" "$phase" "$LINENO" "$status" >&2; exit "$status"' ERR

: "${DRIVE_CURL_CONFIG:?set DRIVE_CURL_CONFIG to a private curl config}"

temporary_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
work="$temporary_root/chatgpt-export-discovery"
rm -rf "$work"
mkdir -p "$work"

zip_helper="$work/zip-central-directory"
phase=build-parser
cc -std=c99 -Wall -Wextra -Werror -O2 \
  commands/zip-central-directory.c \
  -o "$zip_helper"

fetch_range() {
  local file_id=$1
  local file_size=$2
  local start=$3
  local end=$4
  local length=$5
  local output=$6
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
      "https://www.googleapis.com/drive/v3/files/$file_id?alt=media&supportsAllDrives=true"
  )"

  test "$status" = 206
  tr -d '\r' < "$headers" |
    grep -Fxi "Content-Range: bytes $start-$end/$file_size" >/dev/null
  test "$(wc -c < "$output" | tr -d '[:space:]')" = "$length"
}

inventory_zip() {
  local file_id=$1
  local file_size=$2
  local directory=$3
  local tab tail_spec tail_start tail_end tail_length eocd kind a b c d e
  local central_start central_end central_size member_count
  local zip64_start zip64_end zip64_length locator_offset values unused

  mkdir -p "$directory"
  tab="$(printf '\t')"

  tail_spec="$("$zip_helper" tail "$file_size" 2>"$directory/parser.err")" || return 1
  IFS="$tab" read -r tail_start tail_end tail_length <<EOF
$tail_spec
EOF
  fetch_range "$file_id" "$file_size" "$tail_start" "$tail_end" "$tail_length" "$directory/tail.bin" ||
    return 1

  eocd="$("$zip_helper" eocd "$file_size" "$tail_start" "$directory/tail.bin" 2>>"$directory/parser.err")" ||
    return 1
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
      fetch_range "$file_id" "$file_size" "$zip64_start" "$zip64_end" "$zip64_length" "$directory/zip64-eocd.bin" ||
        return 1
      values="$("$zip_helper" zip64-eocd "$file_size" "$zip64_start" "$locator_offset" "$directory/zip64-eocd.bin" 2>>"$directory/parser.err")" ||
        return 1
      IFS="$tab" read -r central_start central_end central_size member_count unused <<EOF
$values
EOF
      ;;
    *)
      return 1
      ;;
  esac

  if test "$central_size" -eq 0; then
    : > "$directory/central.bin"
  else
    fetch_range "$file_id" "$file_size" "$central_start" "$central_end" "$central_size" "$directory/central.bin" ||
      return 1
  fi

  "$zip_helper" list "$central_start" "$central_size" "$member_count" "$directory/central.bin" \
    > "$directory/members.ndjson" 2>>"$directory/parser.err" ||
    return 1

  printf 'kind=%s\nmember_count=%s\ncentral_size=%s\n' \
    "$kind" "$member_count" "$central_size" > "$directory/inventory.meta"
}

phase=list-drive-candidates
stored_file="$work/stored-files.ndjson"
candidate_file="$work/zip-candidates.ndjson"
: > "$stored_file"
: > "$candidate_file"

page_token=
while :; do
  response="$work/list-all-$RANDOM.json"
  set -- \
    --config "$DRIVE_CURL_CONFIG" \
    --silent \
    --show-error \
    --get \
    --data-urlencode 'pageSize=1000' \
    --data-urlencode 'spaces=drive' \
    --data-urlencode 'corpora=user' \
    --data-urlencode 'supportsAllDrives=true' \
    --data-urlencode 'includeItemsFromAllDrives=true' \
    --data-urlencode 'fields=nextPageToken,files(id,size,createdTime,modifiedTime,capabilities(canDownload))' \
    --output "$response" \
    --write-out '%{http_code}'
  if test -n "$page_token"; then
    set -- "$@" --data-urlencode "pageToken=$page_token"
  fi

  status="$(curl "$@" 'https://www.googleapis.com/drive/v3/files')"
  test "$status" = 200

  jq -c '
    .files[]
    | select(.capabilities.canDownload == true)
    | select(.size != null)
    | select((.size | tonumber) >= 4)
    | {id,size,createdTime,modifiedTime}
  ' "$response" >> "$stored_file"

  page_token="$(jq -r '.nextPageToken // ""' "$response")"
  test -n "$page_token" || break
done

stored_count="$(wc -l < "$stored_file" | tr -d '[:space:]')"
printf 'drive_stored_file_count=%s\n' "$stored_count"

phase=probe-zip-magic
probed=0
while IFS= read -r candidate; do
  probed=$((probed + 1))
  file_id="$(printf '%s' "$candidate" | jq -r '.id')"
  file_size="$(printf '%s' "$candidate" | jq -r '.size')"
  prefix="$work/prefix-$probed.bin"
  headers="$prefix.headers"

  status="$(
    curl \
      --config "$DRIVE_CURL_CONFIG" \
      --silent \
      --show-error \
      --request GET \
      --header 'Range: bytes=0-3' \
      --dump-header "$headers" \
      --max-filesize 4 \
      --output "$prefix" \
      --write-out '%{http_code}' \
      "https://www.googleapis.com/drive/v3/files/$file_id?alt=media&supportsAllDrives=true"
  )" || continue

  test "$status" = 206 || continue
  test "$(wc -c < "$prefix" | tr -d '[:space:]')" = 4 || continue

  magic="$(od -An -tx1 -v "$prefix" | tr -d '[:space:]')"
  case "$magic" in
    504b0304|504b0506|504b0708)
      printf '%s\n' "$candidate" >> "$candidate_file"
      ;;
  esac
done < "$stored_file"

candidate_count="$(wc -l < "$candidate_file" | tr -d '[:space:]')"
printf 'drive_files_magic_probed=%s\n' "$probed"
printf 'drive_zip_magic_candidate_count=%s\n' "$candidate_count"
test "$candidate_count" -gt 0

phase=scan-zip-central-directories
match_file="$work/matches.ndjson"
: > "$match_file"
scanned=0
valid_zip_count=0
match_count=0

while IFS= read -r candidate; do
  scanned=$((scanned + 1))
  file_id="$(printf '%s' "$candidate" | jq -r '.id')"
  file_size="$(printf '%s' "$candidate" | jq -r '.size')"
  modified_time="$(printf '%s' "$candidate" | jq -r '.modifiedTime // ""')"
  candidate_dir="$work/candidate-$scanned"

  if ! inventory_zip "$file_id" "$file_size" "$candidate_dir"; then
    continue
  fi
  valid_zip_count=$((valid_zip_count + 1))

  jq -c '
    . as $member
    | (.path | split("/") | last) as $base
    | select(
        $base == "conversations.json" or
        $base == "chat.html" or
        $base == "user.json" or
        $base == "message_feedback.json" or
        $base == "shared_conversations.json"
      )
  ' "$candidate_dir/members.ndjson" > "$candidate_dir/core.ndjson"

  conversations_count="$(
    jq -s '[.[] | select((.path | split("/") | last) == "conversations.json")] | length'       "$candidate_dir/core.ndjson"
  )"
  chat_count="$(
    jq -s '[.[] | select((.path | split("/") | last) == "chat.html")] | length'       "$candidate_dir/core.ndjson"
  )"
  user_count="$(
    jq -s '[.[] | select((.path | split("/") | last) == "user.json")] | length'       "$candidate_dir/core.ndjson"
  )"

  if test "$conversations_count" -eq 1 &&
     { test "$chat_count" -eq 1 || test "$user_count" -eq 1; }
  then
    match_count=$((match_count + 1))
    jq -cn \
      --arg id "$file_id" \
      --arg size "$file_size" \
      --arg modified "$modified_time" \
      --arg directory "$candidate_dir" \
      '{id:$id,size:$size,modified_time:$modified,directory:$directory}' \
      >> "$match_file"
  fi
done < "$candidate_file"

printf 'drive_zip_candidates_scanned=%s\n' "$scanned"
printf 'valid_zip_inventories=%s\n' "$valid_zip_count"
printf 'chatgpt_export_matches=%s\n' "$match_count"

test "$match_count" -gt 0 || {
  printf '%s\n' 'FAIL: no Drive ZIP has the standard ChatGPT export signature (conversations.json plus chat.html or user.json).' >&2
  exit 4
}

if test "$match_count" -ne 1; then
  printf '%s\n' 'FAIL: multiple Drive ZIPs have a ChatGPT export signature; refusing to choose silently.' >&2
  jq -c '{id,size,modified_time}' "$match_file"
  exit 5
fi

match="$(sed -n '1p' "$match_file")"
target_id="$(printf '%s' "$match" | jq -r '.id')"
target_size="$(printf '%s' "$match" | jq -r '.size')"
target_modified="$(printf '%s' "$match" | jq -r '.modified_time')"
target_dir="$(printf '%s' "$match" | jq -r '.directory')"

printf 'chatgpt_export_file_id=%s\n' "$target_id"
printf 'chatgpt_export_size=%s\n' "$target_size"
printf 'chatgpt_export_modified_time=%s\n' "$target_modified"

jq -c '
  {path,compressed_size,uncompressed_size,compression_method,crc32,general_purpose_flags,local_header_offset}
' "$target_dir/core.ndjson"

phase=select-conversations
conversations_member="$work/conversations-member.json"
jq -c '
  select((.path | split("/") | last) == "conversations.json")
' "$target_dir/core.ndjson" > "$conversations_member"
test "$(wc -l < "$conversations_member" | tr -d '[:space:]')" = 1

offset="$(jq -r '.local_header_offset' "$conversations_member")"
compressed_size="$(jq -r '.compressed_size' "$conversations_member")"
expected_uncompressed="$(jq -r '.uncompressed_size' "$conversations_member")"
expected_method="$(jq -r '.compression_method' "$conversations_member")"
expected_flags="$(jq -r '.general_purpose_flags' "$conversations_member")"
expected_crc="$(jq -r '.crc32' "$conversations_member")"
expected_path="$(jq -r '.path' "$conversations_member")"

phase=read-local-header
fixed_end=$((offset + 29))
fetch_range "$target_id" "$target_size" "$offset" "$fixed_end" 30 "$work/local-fixed.bin"

header_info="$(
  python3 - "$work/local-fixed.bin" <<'PY'
import struct
import sys

data = open(sys.argv[1], 'rb').read()
if len(data) != 30:
    raise SystemExit('local fixed header must be 30 bytes')
signature, version, flags, method, mtime, mdate, crc, compressed, uncompressed, name_length, extra_length = struct.unpack('<IHHHHHIIIHH', data)
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
fetch_range "$target_id" "$target_size" "$offset" "$header_end" "$header_length" "$work/local-header.bin"

actual_path="$(
  python3 - "$work/local-header.bin" "$name_length" <<'PY'
import sys

data = open(sys.argv[1], 'rb').read()
name_length = int(sys.argv[2])
sys.stdout.write(data[30:30 + name_length].decode('utf-8'))
PY
)"
test "$actual_path" = "$expected_path"

phase=read-conversations-payload
data_start=$((offset + header_length))
data_end=$((data_start + compressed_size - 1))
fetch_range "$target_id" "$target_size" "$data_start" "$data_end" "$compressed_size" "$work/conversations.compressed"

phase=decompress-conversations
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

phase=verify-conversations-json
jq -e 'type == "array"' "$work/conversations.json" >/dev/null
conversation_count="$(jq 'length' "$work/conversations.json")"
output_sha256="$(sha256sum "$work/conversations.json" | awk '{print $1}')"

printf 'conversation_count=%s\n' "$conversation_count"
printf 'conversations_sha256=%s\n' "$output_sha256"
printf '%s\n' 'PASS: actual ChatGPT export located in Drive and conversations.json selectively unzipped by bounded remote ranges, with size, CRC32, JSON shape, and SHA-256 verified.'
printf '%s\n' 'NOTE: private conversations.json stayed only on the ephemeral runner and was not published.'
