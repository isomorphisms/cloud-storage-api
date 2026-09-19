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
warnings.filterwarnings('ignore', message='Duplicate name:.*')
root=sys.argv[1]

def write_zip(path, entries):
    with zipfile.ZipFile(path, 'w', allowZip64=False) as archive:
        for name, data, method in entries:
            info=zipfile.ZipInfo(name, (2026,1,1,0,0,0)); info.compress_type=method
            archive.writestr(info,data)

write_zip(os.path.join(root,'safe.zip'), [
 ('Takeout/My Activity/Search/MyActivity.json',b'{"search":1}\n',zipfile.ZIP_DEFLATED),
 ('Takeout/Chrome/History.json',b'{"history":1}\n',zipfile.ZIP_DEFLATED),
 ('notes/readme.txt',b'fixture\n',zipfile.ZIP_STORED),
 ('padding.bin',b'x'*200000,zipfile.ZIP_STORED)])
write_zip(os.path.join(root,'traversal.zip'), [('../escape.txt',b'x',0)])
write_zip(os.path.join(root,'duplicate.zip'), [('same.txt',b'a',0),('same.txt',b'b',0)])
write_zip(os.path.join(root,'unsupported.zip'), [('x.txt',b'x',0)])
b=bytearray(open(os.path.join(root,'unsupported.zip'),'rb').read()); pos=b.find(b'PK\x01\x02'); struct.pack_into('<H',b,pos+10,99); open(os.path.join(root,'unsupported.zip'),'wb').write(b)
write_zip(os.path.join(root,'zip64-marker.zip'), [('x.txt',b'x',0)])
b=bytearray(open(os.path.join(root,'zip64-marker.zip'),'rb').read()); pos=b.rfind(b'PK\x05\x06'); struct.pack_into('<I',b,pos+16,0xffffffff); open(os.path.join(root,'zip64-marker.zip'),'wb').write(b)
write_zip(os.path.join(root,'nul-name.zip'), [('abc.txt',b'x',0)])
b=bytearray(open(os.path.join(root,'nul-name.zip'),'rb').read()); pos=b.find(b'PK\x01\x02'); b[pos+46]=0; open(os.path.join(root,'nul-name.zip'),'wb').write(b)
write_zip(os.path.join(root,'newer-version.zip'), [('x.txt', b'x', 0)])
b=bytearray(open(os.path.join(root,'newer-version.zip'),'rb').read())
pos=b.find(b'PK\x01\x02'); struct.pack_into('<H', b, pos + 6, 46)
open(os.path.join(root,'newer-version.zip'),'wb').write(b)

# Valid sparse ZIP64 fixture: central directory starts at 5 GiB and the member
# sizes are also 5 GiB, but sparse storage keeps the fixture cheap.
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
    IFS="$tab" read -r archive_kind field_1 field_2 field_3 field_4 field_5 <<EOF_EOCD
$eocd
EOF_EOCD
    case $archive_kind in
        classic)
            central_start=$field_1; central_end=$field_2; central_size=$field_3; member_count=$field_4; eocd_offset=$field_5
            ;;
        zip64)
            zip64_start=$field_1; zip64_end=$field_2; zip64_length=$field_3; locator_offset=$field_4; eocd_offset=$field_5
            dd if="$archive" of="$temporary/zip64-eocd.bin" bs=1 skip="$zip64_start" count="$zip64_length" status=none
            zip64_values=$($helper zip64-eocd "$size" "$zip64_start" "$locator_offset" "$temporary/zip64-eocd.bin")
            IFS="$tab" read -r central_start central_end central_size member_count unused <<EOF_Z64
$zip64_values
EOF_Z64
            ;;
        *) printf 'unexpected archive kind: %s\n' "$archive_kind" >&2; return 1 ;;
    esac
    dd if="$archive" of="$temporary/central.bin" bs=1 skip="$central_start" count="$central_size" status=none
}

range_parts "$temporary/safe.zip"
[ "$archive_kind" = classic ]
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

range_parts "$temporary/zip64.zip"
[ "$archive_kind" = zip64 ]
zip64=$($helper list "$central_start" "$central_size" "$member_count" "$temporary/central.bin")
printf '%s\n' "$zip64" | grep -F '"path":"Takeout/big.bin"' >/dev/null
printf '%s\n' "$zip64" | grep -F '"compressed_size":5368709120' >/dev/null
printf '%s\n' "$zip64" | grep -F '"uncompressed_size":5368709120' >/dev/null
printf '%s\n' "$zip64" | grep -F '"central_directory_record_offset":5368709120' >/dev/null

reject() {
    archive=$1; expected=$2
    if range_parts "$archive" 2>"$temporary/range.err"; then
        if $helper list "$central_start" "$central_size" "$member_count" "$temporary/central.bin" >/dev/null 2>"$temporary/reject.err"; then
            printf 'unsafe fixture unexpectedly passed: %s\n' "$archive" >&2; exit 1
        fi
        grep -F "$expected" "$temporary/reject.err" >/dev/null
    else
        grep -F "$expected" "$temporary/range.err" >/dev/null
    fi
}
reject "$temporary/traversal.zip" 'path traversal'
reject "$temporary/duplicate.zip" 'duplicate ZIP member names'
reject "$temporary/unsupported.zip" 'compression method is unsupported'
reject "$temporary/zip64-marker.zip" 'ZIP64 end-of-central-directory locator is missing'
reject "$temporary/nul-name.zip" 'member name contains NUL'
reject "$temporary/newer-version.zip" 'newer than version 4.5'

: > "$temporary/empty.bin"
if $helper list 0 67108865 1 "$temporary/empty.bin" >/dev/null 2>"$temporary/bound.err"; then
    printf '%s\n' 'oversized central directory unexpectedly accepted' >&2; exit 1
fi
grep -F 'exceeds the 64 MiB inventory bound' "$temporary/bound.err" >/dev/null

printf '%s\n' 'deterministic bounded classic ZIP and ZIP64 central-directory fixtures pass'
