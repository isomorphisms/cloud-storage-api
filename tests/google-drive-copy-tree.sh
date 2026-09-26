#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
fake_bin=$temporary/bin
log=$temporary/curl-arguments.txt
state=$temporary/copied-state.tsv
post_count=$temporary/post-count.txt
mkdir -p "$fake_bin"
: > "$log"
: > "$state"
printf '%s\n' 0 > "$post_count"

: "${GREASE:?set GREASE to the Grease executable under test}"

cat > "$fake_bin/curl" <<'EOF_CURL'
#!/bin/sh
set -eu

: "${FAKE_CURL_LOG:?}"
: "${FAKE_DRIVE_STATE:?}"
: "${FAKE_POST_COUNT:?}"

for argument in "$@"; do
    printf '%s\n' "$argument" >> "$FAKE_CURL_LOG"
done

method=GET
url=
body_argument=

while [ "$#" -gt 0 ]; do
    case $1 in
        --request)
            method=$2
            shift 2
            ;;
        --data-binary)
            body_argument=$2
            shift 2
            ;;
        http://*|https://*)
            url=$1
            shift
            ;;
        *)
            shift
            ;;
    esac
done

folder_mime=application/vnd.google-apps.folder

source_mime() {
    case $1 in
        SOURCE|FOLDER1)
            printf '%s\n' "$folder_mime"
            ;;
        FILE1|FILE3)
            printf '%s\n' text/markdown
            ;;
        FILE2)
            printf '%s\n' application/x-xz
            ;;
        *)
            printf '%s\n' application/octet-stream
            ;;
    esac
}

if [ "$method" = GET ]; then
    case $url in
        *'/files/SOURCE?'*)
            printf '%s\n' '{"id":"SOURCE","name":"Summaries","mimeType":"application/vnd.google-apps.folder","capabilities":{"canListChildren":true}}'
            exit 0
            ;;
        *'/files/DESTROOT?'*)
            printf '%s\n' '{"id":"DESTROOT","name":"My Drive","mimeType":"application/vnd.google-apps.folder","parents":[]}'
            exit 0
            ;;
        *'/files?'*appProperties*)
            marker_source=
            for candidate in SOURCE FOLDER1 FILE1 FILE2 FILE3; do
                case $url in
                    *"value%3D%27$candidate%27"*)
                        marker_source=$candidate
                        break
                        ;;
                esac
            done

            if [ -n "$marker_source" ]; then
                existing=$(awk -F '\t' -v source="$marker_source" '$1 == source {print; exit}' "$FAKE_DRIVE_STATE")
            else
                existing=
            fi

            if [ -n "$existing" ]; then
                existing_id=$(printf '%s\n' "$existing" | cut -f2)
                existing_mime=$(printf '%s\n' "$existing" | cut -f3)
                jq -cn \
                    --arg id "$existing_id" \
                    --arg mime "$existing_mime" \
                    --arg source "$marker_source" \
                    '{files:[{id:$id,name:"existing",mimeType:$mime,appProperties:{cloud_storage_api_source_id:$source}}]}'
            else
                printf '%s\n' '{"files":[]}'
            fi
            exit 0
            ;;
        *'/files?'*pageToken%3DPAGE2*|*'/files?'*pageToken=PAGE2*)
            printf '%s\n' '{"files":[{"id":"FILE2","name":"compressed.md.xz","mimeType":"application/x-xz","capabilities":{"canCopy":true}}]}'
            exit 0
            ;;
        *'/files?'*FOLDER1*in%20parents*)
            printf '%s\n' '{"files":[{"id":"FILE3","name":"nested.md","mimeType":"text/markdown","capabilities":{"canCopy":true}}]}'
            exit 0
            ;;
        *'/files?'*SOURCE*in%20parents*)
            printf '%s\n' '{"files":[{"id":"FOLDER1","name":"papers","mimeType":"application/vnd.google-apps.folder","capabilities":{"canListChildren":true}},{"id":"FILE1","name":"top.md","mimeType":"text/markdown","capabilities":{"canCopy":true}}],"nextPageToken":"PAGE2"}'
            exit 0
            ;;
    esac
fi

if [ "$method" = POST ]; then
    count=$(cat "$FAKE_POST_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FAKE_POST_COUNT"

    body_file=${body_argument#@}
    source_id=$(jq -r '.appProperties.cloud_storage_api_source_id' "$body_file")
    destination_id=COPY_$source_id

    case $url in
        *'/files/'*'/copy?'*)
            mime=$(source_mime "$source_id")
            ;;
        *'/files?'*)
            mime=$(jq -r '.mimeType' "$body_file")
            ;;
        *)
            printf 'unexpected POST URL: %s\n' "$url" >&2
            exit 1
            ;;
    esac

    printf '%s\t%s\t%s\n' "$source_id" "$destination_id" "$mime" >> "$FAKE_DRIVE_STATE"
    jq -cn \
        --arg id "$destination_id" \
        --arg mime "$mime" \
        --arg source "$source_id" \
        '{id:$id,name:"copy",mimeType:$mime,appProperties:{cloud_storage_api_source_id:$source}}'
    exit 0
fi

printf 'unexpected fake Drive request: %s %s\n' "$method" "$url" >&2
exit 1
EOF_CURL
chmod +x "$fake_bin/curl"

client=$root/commands/google-drive-copy-tree.grease
common_path=$fake_bin:$PATH

run_client() {
    PATH=$common_path \
    GOOGLE_ACCESS_TOKEN=SECRET_TOKEN_VALUE \
    FAKE_CURL_LOG=$log \
    FAKE_DRIVE_STATE=$state \
    FAKE_POST_COUNT=$post_count \
    GREASE="$GREASE" \
        "$GREASE" "$client" "$@"
}

assert_summary() {
    output=$1
    expected=$2
    actual=$(printf '%s\n' "$output" |
        jq -r 'select(.kind == "summary") | [.folders_created,.folders_reused,.files_copied,.files_reused] | @tsv')
    [ "$actual" = "$expected" ] || {
        printf 'unexpected summary: %s\n' "$actual" >&2
        printf '%s\n' "$output" >&2
        exit 1
    }
}

first_output=$(run_client \
    'https://drive.google.com/drive/folders/SOURCE?usp=sharing' \
    'https://drive.google.com/drive/folders/DESTROOT')
assert_summary "$first_output" '2	0	3	0'
[ "$(cat "$post_count")" -eq 5 ] || {
    printf 'expected five Drive writes, got %s\n' "$(cat "$post_count")" >&2
    exit 1
}
[ "$(wc -l < "$state" | tr -d '[:space:]')" -eq 5 ] || {
    printf '%s\n' 'copy marker state did not record all five objects' >&2
    cat "$state" >&2
    exit 1
}

printf '%s\n' "$first_output" |
    jq -e 'select(.kind == "folder" and .source_id == "SOURCE" and .status == "created")' >/dev/null
printf '%s\n' "$first_output" |
    jq -e 'select(.kind == "file" and .source_id == "FILE3" and .status == "copied")' >/dev/null

grep -F 'pageToken=PAGE2' "$log" >/dev/null || {
    printf '%s\n' 'pagination token was not used' >&2
    cat "$log" >&2
    exit 1
}

second_output=$(run_client SOURCE DESTROOT)
assert_summary "$second_output" '0	2	0	3'
[ "$(cat "$post_count")" -eq 5 ] || {
    printf '%s\n' 'second run performed duplicate Drive writes' >&2
    exit 1
}

printf '%s\n' "$second_output" |
    jq -e 'select(.kind == "folder" and .source_id == "SOURCE" and .status == "reused")' >/dev/null
printf '%s\n' "$second_output" |
    jq -e 'select(.kind == "file" and .source_id == "FILE2" and .status == "reused")' >/dev/null

if grep -F 'SECRET_TOKEN_VALUE' "$log" >/dev/null; then
    printf '%s\n' 'bearer token leaked into curl argv' >&2
    cat "$log" >&2
    exit 1
fi

help=$("$GREASE" "$client" --help)
printf '%s\n' "$help" | grep -F 'google-drive-copy-tree SOURCE_FOLDER' >/dev/null
printf '%s\n' "$help" | grep -F 'does not clone' >/dev/null

printf '%s\n' 'google-drive-copy-tree Grease contract passes'
