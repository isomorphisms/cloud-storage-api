#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
fake_bin=$temporary/bin
mkdir -p "$fake_bin"

: "${GREASE:?set GREASE to the Grease/YSH executable under test}"

cat > "$fake_bin/jq" <<'EOF_JQ'
#!/usr/bin/env python2
from __future__ import print_function

import json
import sys

arguments = sys.argv[1:]

if '-n' in arguments:
    values = {}
    i = 0
    while i < len(arguments):
        if arguments[i] == '--arg':
            values[arguments[i + 1]] = arguments[i + 2]
            i += 3
        else:
            i += 1
    json.dump({
        'function': 'unzip_drive_file',
        'parameters': [values.get('zip_id', ''), values.get('destination_id', '')],
        'devMode': False,
    }, sys.stdout, separators=(',', ':'))
    sys.stdout.write('\n')
    sys.exit(0)

filter_text = None
for argument in arguments:
    if not argument.startswith('-'):
        filter_text = argument
        break

if filter_text is None or not arguments:
    sys.exit(64)

path = arguments[-1]
with open(path) as source:
    value = json.load(source)

if 'function == "unzip_drive_file"' in filter_text:
    passed = (
        value.get('function') == 'unzip_drive_file' and
        value.get('parameters') == ['ZIP123', 'DEST456'] and
        value.get('devMode') is False
    )
    sys.exit(0 if passed else 1)

if filter_text == '.error? != null':
    sys.exit(0 if value.get('error') is not None else 1)

if filter_text == '.response.error? != null':
    response = value.get('response') or {}
    sys.exit(0 if response.get('error') is not None else 1)

if '.response? != null' in filter_text and '.response.result? != null' in filter_text:
    response = value.get('response')
    passed = response is not None and response.get('result') is not None
    sys.exit(0 if passed else 1)

if filter_text == '.response.result':
    result = value['response']['result']
    json.dump(result, sys.stdout, separators=(',', ':'))
    sys.stdout.write('\n')
    sys.exit(0)

print('unsupported fake jq filter: %s' % filter_text, file=sys.stderr)
sys.exit(64)
EOF_JQ
chmod +x "$fake_bin/jq"

cat > "$fake_bin/curl" <<'EOF_CURL'
#!/bin/sh
set -eu
request=
for argument in "$@"; do
    case $argument in
        @*) request=${argument#@} ;;
    esac
done
[ -n "$request" ] || {
    printf '%s\n' 'fake curl did not receive @request' >&2
    exit 64
}

case ${FAKE_APPS_SCRIPT_RESULT:-success} in
    success)
        jq -e '
            .function == "unzip_drive_file" and
            .parameters[0] == "ZIP123" and
            .parameters[1] == "DEST456" and
            .devMode == false
        ' "$request" >/dev/null
        printf '%s\n' '{"response":{"result":{"output_folder_id":"OUT123","members":3}}}'
        ;;
    top-error)
        printf '%s\n' '{"error":{"code":403,"message":"denied"}}'
        ;;
    script-error)
        printf '%s\n' '{"response":{"error":{"code":3,"message":"ScriptError"}}}'
        ;;
    missing-result)
        printf '%s\n' '{"response":{}}'
        ;;
    *)
        printf 'unknown fake result: %s\n' "$FAKE_APPS_SCRIPT_RESULT" >&2
        exit 64
        ;;
esac
EOF_CURL
chmod +x "$fake_bin/curl"

client=$root/commands/google-drive-unzip.ysh
common_path=$fake_bin:$PATH

run_client() {
    export PATH GOOGLE_APPS_SCRIPT_DEPLOYMENT_ID GOOGLE_ACCESS_TOKEN FAKE_APPS_SCRIPT_RESULT
    "$GREASE" "$client" "$@"
}

output=$(
    PATH=$common_path \
    GOOGLE_APPS_SCRIPT_DEPLOYMENT_ID=DEPLOY123 \
    GOOGLE_ACCESS_TOKEN=TOKEN123 \
    FAKE_APPS_SCRIPT_RESULT=success \
        run_client \
        'https://drive.google.com/file/d/ZIP123/view?usp=sharing' \
        'https://drive.google.com/drive/folders/DEST456?usp=sharing'
)
[ "$output" = '{"output_folder_id":"OUT123","members":3}' ] || {
    printf 'unexpected success result: %s\n' "$output" >&2
    exit 1
}

for mode in top-error script-error missing-result; do
    if PATH=$common_path \
       GOOGLE_APPS_SCRIPT_DEPLOYMENT_ID=DEPLOY123 \
       GOOGLE_ACCESS_TOKEN=TOKEN123 \
       FAKE_APPS_SCRIPT_RESULT=$mode \
       run_client ZIP123 DEST456 >/dev/null 2>&1
    then
        printf 'error response unexpectedly succeeded: %s\n' "$mode" >&2
        exit 1
    fi
done

help=$(run_client --help)
printf '%s\n' "$help" | grep -F 'google-drive-unzip DRIVE_ZIP' >/dev/null

printf 'grease=%s\n' "$GREASE"
printf '%s\n' 'google-drive-unzip Grease contract passes'
