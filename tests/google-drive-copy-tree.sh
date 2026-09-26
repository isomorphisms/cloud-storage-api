#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
state=$temporary/state
log=$temporary/log
: > "$state"
: > "$log"

: "${GREASE:?set GREASE to the Grease executable under test}"

cat > "$temporary/fake-api.grease" <<'EOF_API'
#!/usr/bin/env grease
set -eu
: "${FAKE_STATE:?}"
: "${FAKE_LOG:?}"
method=$1
shift
printf '%s' "$method" >> "$FAKE_LOG"
for argument in "$@"; do printf ' <%s>' "$argument" >> "$FAKE_LOG"; done
printf '\n' >> "$FAKE_LOG"
path_id=
query=
body=
while [ "$#" -gt 0 ]; do
    case $1 in
        --path)
            case $2 in fileId=*) path_id=${2#fileId=} ;; esac
            shift 2
            ;;
        --query)
            case $2 in q=*) query=${2#q=} ;; esac
            shift 2
            ;;
        --body) body=$2; shift 2 ;;
        *) shift ;;
    esac
done
case $method in
    drive.files.get)
        case $path_id in
            ROOT) printf '%s\n' '{"id":"ROOT","name":"library","mimeType":"application/vnd.google-apps.folder","version":"10"}' ;;
            DEST) printf '%s\n' '{"id":"DEST","name":"My Drive","mimeType":"application/vnd.google-apps.folder","capabilities":{"canAddChildren":true}}' ;;
            *) exit 70 ;;
        esac
        ;;
    drive.files.list)
        case $query in
            *"appProperties has"*)
                source=$(printf '%s\n' "$query" | sed -n "s/.*key='cloud_storage_api_source_id' and value='\([^']*\)'.*/\1/p")
                role=$(printf '%s\n' "$query" | sed -n "s/.*key='cloud_storage_api_copy_role' and value='\([^']*\)'.*/\1/p")
                version=$(printf '%s\n' "$query" | sed -n "s/.*key='cloud_storage_api_source_version' and value='\([^']*\)'.*/\1/p")
                parent=$(printf '%s\n' "$query" | sed -n "s/^'\([^']*\)' in parents.*/\1/p")
                line=$(awk -F '\t' -v s="$source" -v r="$role" -v v="$version" -v p="$parent" \
                    '($1==s && $2==r && $4==p && (v=="" || $3==v)){print; exit}' "$FAKE_STATE")
                if [ -z "$line" ]; then
                    printf '%s\n' '{"files":[]}'
                else
                    dest_id=$(printf '%s\n' "$line" | cut -f5)
                    name=$(printf '%s\n' "$line" | cut -f6)
                    mime=$(printf '%s\n' "$line" | cut -f7)
                    size=$(printf '%s\n' "$line" | cut -f8)
                    sha=$(printf '%s\n' "$line" | cut -f9)
                    jq -cn --arg id "$dest_id" --arg n "$name" --arg m "$mime" --arg s "$size" --arg h "$sha" \
                      '{files:[{id:$id,name:$n,mimeType:$m} + (if $s=="" then {} else {size:$s} end) + (if $h=="" then {} else {sha256Checksum:$h} end)]}'
                fi
                ;;
            *"'ROOT' in parents"*)
                printf '%s\n' '{"files":[{"id":"DIR1","name":"papers","mimeType":"application/vnd.google-apps.folder","version":"20"},{"id":"FILE1","name":"paper.pdf","mimeType":"application/pdf","size":"5","version":"30","sha256Checksum":"abc","modifiedTime":"2026-01-02T03:04:05Z","capabilities":{"canCopy":true}}]}'
                ;;
            *"'DIR1' in parents"*)
                printf '%s\n' '{"files":[{"id":"FILE2","name":"notes","mimeType":"application/vnd.google-apps.document","version":"40","modifiedTime":"2026-02-03T04:05:06Z","capabilities":{"canCopy":true}}]}'
                ;;
            *)
                printf 'unexpected q: %s\n' "$query" >&2
                exit 71
                ;;
        esac
        ;;
    drive.files.create)
        source=$(jq -r '.appProperties.cloud_storage_api_source_id' "$body")
        role=$(jq -r '.appProperties.cloud_storage_api_copy_role' "$body")
        parent=$(jq -r '.parents[0]' "$body")
        name=$(jq -r '.name' "$body")
        case $source in ROOT) dest_id=DROOT ;; DIR1) dest_id=DDIR1 ;; *) exit 72 ;; esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t\n' \
            "$source" "$role" '' "$parent" "$dest_id" "$name" 'application/vnd.google-apps.folder' >> "$FAKE_STATE"
        jq -cn --arg id "$dest_id" --arg n "$name" '{id:$id,name:$n,mimeType:"application/vnd.google-apps.folder"}'
        ;;
    drive.files.copy)
        source=$path_id
        version=$(jq -r '.appProperties.cloud_storage_api_source_version' "$body")
        parent=$(jq -r '.parents[0]' "$body")
        name=$(jq -r '.name' "$body")
        case $source in
            FILE1) dest_id=DFILE1; mime=application/pdf; size=5; sha=abc ;;
            FILE2) dest_id=DFILE2; mime=application/vnd.google-apps.document; size=; sha= ;;
            *) exit 73 ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$source" file "$version" "$parent" "$dest_id" "$name" "$mime" "$size" "$sha" >> "$FAKE_STATE"
        jq -cn --arg id "$dest_id" --arg n "$name" --arg m "$mime" --arg s "$size" --arg h "$sha" \
          '{id:$id,name:$n,mimeType:$m} + (if $s=="" then {} else {size:$s} end) + (if $h=="" then {} else {sha256Checksum:$h} end)'
        ;;
    *) exit 74 ;;
esac
EOF_API
chmod +x "$temporary/fake-api.grease"

client=$root/commands/google-drive-files.grease
run_copy() {
    FAKE_STATE=$state \
    FAKE_LOG=$log \
    GOOGLE_DRIVE_API=$temporary/fake-api.grease \
    GREASE="$GREASE" \
        "$GREASE" "$client" copy-tree "$@"
}

first=$(run_copy 'https://drive.google.com/drive/folders/ROOT?usp=sharing' DEST --name archive)
printf '%s\n' "$first" | tail -n 1 | jq -e \
    '.kind=="summary" and .source_items==4 and .destination_items==4 and .created==4 and .reused==0 and .failed==0 and .complete==true' >/dev/null
[ "$(wc -l < "$state" | tr -d '[:space:]')" = 4 ]
awk -F '\t' '$1=="DIR1" && $4=="DROOT" {found=1} END{exit !found}' "$state"
awk -F '\t' '$1=="FILE1" && $4=="DROOT" {found=1} END{exit !found}' "$state"
awk -F '\t' '$1=="FILE2" && $4=="DDIR1" {found=1} END{exit !found}' "$state"

second=$(run_copy ROOT DEST --name archive)
printf '%s\n' "$second" | tail -n 1 | jq -e \
    '.created==0 and .reused==4 and .failed==0 and .complete==true' >/dev/null
[ "$(wc -l < "$state" | tr -d '[:space:]')" = 4 ]

grep -F 'copyComments=true' "$log" >/dev/null
grep -F 'cloud_storage_api_source_version' "$log" >/dev/null

readonly_credential=$temporary/readonly.credentials
printf '%s\n' \
    'schema=google-drive-oauth-v1' \
    'scope=https://www.googleapis.com/auth/drive.readonly' \
    > "$readonly_credential"
chmod 600 "$readonly_credential"
GOOGLE_DRIVE_CREDENTIAL_FILE=$readonly_credential
export GOOGLE_DRIVE_CREDENTIAL_FILE
if run_copy ROOT DEST --name archive >/dev/null 2>"$temporary/readonly.err"; then
    printf '%s\n' 'read-only credential unexpectedly passed copy-tree preflight' >&2
    exit 1
fi
unset GOOGLE_DRIVE_CREDENTIAL_FILE
grep -F 'drive.readonly + drive.file' "$temporary/readonly.err" >/dev/null

printf '%s\n' 'google-drive-copy-tree restart/reconciliation contract passes'
