#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source_c=${ZIP_CENTRAL_DIRECTORY_SOURCE:-$root/commands/zip-central-directory.c}
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
helper=$temporary/zip-central-directory
cc -std=c99 -Wall -Wextra -Werror -O2 "$source_c" -o "$helper"

python3 - "$temporary" <<'PY'
import os, struct, sys, warnings, zipfile
warnings.filterwarnings("ignore", message="Duplicate name:.*")
root=sys.argv[1]

def write_zip(path, entries):
    with zipfile.ZipFile(path, 'w', allowZip64=False) as archive:
        for name, data, method in entries:
            info=zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type=method
            archive.writestr(info, data)

write_zip(os.path.join(root,'safe.zip'), [
    ('Takeout/My Activity/Search/MyActivity.json', b'{"search":1}\n', zipfile.ZIP_DEFLATED),
    ('Takeout/Chrome/History.json', b'{"history":1}\n', zipfile.ZIP_DEFLATED),
    ('notes/readme.txt', b'fixture\n', zipfile.ZIP_STORED),
    ('padding.bin', b'x' * 200000, zipfile.ZIP_STORED),
])
write_zip(os.path.join(root,'traversal.zip'), [('../escape.txt', b'x', zipfile.ZIP_STORED)])
write_zip(os.path.join(root,'duplicate.zip'), [('same.txt', b'a', 0), ('same.txt', b'b', 0)])
write_zip(os.path.join(root,'unsupported.zip'), [('x.txt', b'x', 0)])
b=bytearray(open(os.path.join(root,'unsupported.zip'),'rb').read())
pos=b.find(b'PK\x01\x02'); struct.pack_into('<H', b, pos + 10, 99)
open(os.path.join(root,'unsupported.zip'),'wb').write(b)
write_zip(os.path.join(root,'zip64-marker.zip'), [('x.txt', b'x', 0)])
b=bytearray(open(os.path.join(root,'zip64-marker.zip'),'rb').read())
pos=b.rfind(b'PK\x05\x06'); struct.pack_into('<I', b, pos + 16, 0xffffffff)
open(os.path.join(root,'zip64-marker.zip'),'wb').write(b)
PY

range_parts() {
    archive=$1
    size=$(wc -c < "$archive" | tr -d '[:space:]')
    tab=$(printf '\t')
    tail_spec=$($helper tail "$size")
    IFS="$tab" read -r tail_start tail_end tail_length <<EOF_TAIL
$tail_spec
EOF_TAIL
    dd if="$archive" of="$temporary/tail.bin" bs=1 skip="$tail_start" count="$tail_length" status=none
    eocd=$($helper eocd "$size" "$tail_start" "$temporary/tail.bin")
    IFS="$tab" read -r central_start central_end central_size member_count eocd_offset <<EOF_EOCD
$eocd
EOF_EOCD
    dd if="$archive" of="$temporary/central.bin" bs=1 skip="$central_start" count="$central_size" status=none
}

range_parts "$temporary/safe.zip"
all=$($helper list "$central_start" "$central_size" "$member_count" "$temporary/central.bin")
printf '%s\n' "$all" | grep -F '"path":"Takeout/My Activity/Search/MyActivity.json"' >/dev/null
printf '%s\n' "$all" | grep -F '"compression_method":8' >/dev/null
printf '%s\n' "$all" | grep -F '"path":"padding.bin"' >/dev/null

prefix=$($helper list "$central_start" "$central_size" "$member_count" --prefix 'Takeout/' "$temporary/central.bin")
[ "$(printf '%s\n' "$prefix" | wc -l | tr -d '[:space:]')" = 2 ]
exact=$($helper list "$central_start" "$central_size" "$member_count" --exact 'notes/readme.txt' "$temporary/central.bin")
printf '%s\n' "$exact" | grep -F '"path":"notes/readme.txt"' >/dev/null
glob=$($helper list "$central_start" "$central_size" "$member_count" --glob 'Takeout/*/*.json' "$temporary/central.bin")
printf '%s\n' "$glob" | grep -F '"path":"Takeout/Chrome/History.json"' >/dev/null

reject() {
    archive=$1
    expected=$2
    if range_parts "$archive" 2>"$temporary/range.err"; then
        if $helper list "$central_start" "$central_size" "$member_count" "$temporary/central.bin" >/dev/null 2>"$temporary/reject.err"; then
            printf 'unsafe fixture unexpectedly passed: %s\n' "$archive" >&2
            exit 1
        fi
        grep -F "$expected" "$temporary/reject.err" >/dev/null
    else
        grep -F "$expected" "$temporary/range.err" >/dev/null
    fi
}
reject "$temporary/traversal.zip" 'path traversal'
reject "$temporary/duplicate.zip" 'duplicate ZIP member names'
reject "$temporary/unsupported.zip" 'compression method is unsupported'
reject "$temporary/zip64-marker.zip" 'ZIP64 archives are unsupported'

printf '%s\n' 'deterministic bounded ZIP central-directory fixture passes'
