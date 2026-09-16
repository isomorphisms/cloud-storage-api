#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
fake_bin=$temporary/bin
mkdir -p "$fake_bin"

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

output=$(
    PATH=$common_path \
    GOOGLE_APPS_SCRIPT_DEPLOYMENT_ID=DEPLOY123 \
    GOOGLE_ACCESS_TOKEN=TOKEN123 \
    FAKE_APPS_SCRIPT_RESULT=success \
        sh "$client" \
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
       sh "$client" ZIP123 DEST456 >/dev/null 2>&1
    then
        printf 'error response unexpectedly succeeded: %s\n' "$mode" >&2
        exit 1
    fi
done

help=$(sh "$client" --help)
printf '%s\n' "$help" | grep -F 'google-drive-unzip DRIVE_ZIP' >/dev/null

printf '%s\n' 'google-drive-unzip compatibility contract passes'
