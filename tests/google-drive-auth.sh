#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
fake_bin=$temporary/bin
mkdir -p "$fake_bin"
: "${GREASE:?set GREASE to the Grease executable under test}"
: "${GOOGLE_OAUTH_LOOPBACK:?set GOOGLE_OAUTH_LOOPBACK to the compiled helper}"

client_json=$temporary/client.json
cat > "$client_json" <<'EOF_CLIENT'
{
  "installed": {
    "client_id": "CLIENT.apps.googleusercontent.com",
    "client_secret": "GOCSPX-CLIENT_SECRET",
    "redirect_uris": ["http://localhost"]
  }
}
EOF_CLIENT
chmod 600 "$client_json"

curl_log=$temporary/curl.argv
form_log=$temporary/token.forms
: > "$curl_log"
: > "$form_log"
cat > "$fake_bin/curl" <<'EOF_CURL'
#!/bin/sh
set -eu
: "${FAKE_CURL_LOG:?}"
: "${FAKE_FORM_LOG:?}"
{
    printf '%s\n' '=== curl ==='
    for argument in "$@"; do printf '%s\n' "$argument"; done
} >> "$FAKE_CURL_LOG"

output=
form=
while [ "$#" -gt 0 ]; do
    case $1 in
        --output) output=$2; shift 2 ;;
        --data-binary) form=${2#@}; shift 2 ;;
        --header|--write-out) shift 2 ;;
        --fail-with-body|--silent|--show-error) shift ;;
        http*) shift ;;
        *) shift ;;
    esac
done
[ -n "$output" ] && [ -n "$form" ] || exit 91
cat "$form" >> "$FAKE_FORM_LOG"
printf '\n' >> "$FAKE_FORM_LOG"

if grep -F 'grant_type=authorization_code' "$form" >/dev/null; then
    if [ "${FAKE_SCOPE_FAILURE:-0}" = 1 ]; then
        printf '%s\n' '{"access_token":"ACCESS_WRONG_SCOPE","expires_in":3600,"refresh_token":"REFRESH_WRONG_SCOPE","scope":"https://www.googleapis.com/auth/drive.metadata.readonly","token_type":"Bearer"}' > "$output"
    else
        printf '%s\n' '{"access_token":"ACCESS_INITIAL","expires_in":3600,"refresh_token":"REFRESH_LONG_LIVED","scope":"https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file","token_type":"Bearer"}' > "$output"
    fi
    printf '%s' 200
elif grep -F 'grant_type=refresh_token' "$form" >/dev/null; then
    if [ "${FAKE_REFRESH_ERROR:-}" = invalid_grant ]; then
        printf '%s\n' '{"error":"invalid_grant","error_description":"revoked"}' > "$output"
        printf '%s' 400
        exit 22
    fi
    printf '%s\n' '{"access_token":"ACCESS_REFRESHED","expires_in":3600,"scope":"https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file","token_type":"Bearer"}' > "$output"
    printf '%s' 200
else
    exit 92
fi
EOF_CURL
chmod +x "$fake_bin/curl"

client=$root/commands/google-drive-auth.grease
common_env() {
    PATH=$fake_bin:$PATH \
    FAKE_CURL_LOG=$curl_log \
    FAKE_FORM_LOG=$form_log \
    GOOGLE_OAUTH_TEST_ENDPOINTS=1 \
    GOOGLE_OAUTH_AUTHORIZATION_ENDPOINT=https://accounts.example.test/auth \
    GOOGLE_OAUTH_TOKEN_ENDPOINT=https://oauth.example.test/token \
    GOOGLE_OAUTH_LOOPBACK=$GOOGLE_OAUTH_LOOPBACK \
    TMPDIR=$temporary \
        "$GREASE" "$client" "$@"
}

credential=$temporary/config/google-drive.credentials
init_output=$(common_env init "$client_json" "$credential" --create-parent)
printf '%s\n' "$init_output" | grep -F 'authorized=no' >/dev/null
[ "$(stat -c %a "$credential")" = 600 ]
grep -F 'client_id=CLIENT.apps.googleusercontent.com' "$credential" >/dev/null
grep -F 'client_secret=GOCSPX-CLIENT_SECRET' "$credential" >/dev/null

authorization_url=$(common_env begin "$credential" http://127.0.0.1:53682)
printf '%s\n' "$authorization_url" | grep -F 'https://accounts.example.test/auth?' >/dev/null
printf '%s\n' "$authorization_url" | grep -F 'scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.readonly' >/dev/null
printf '%s\n' "$authorization_url" | grep -F 'code_challenge_method=S256' >/dev/null

copy_scope_credential=$temporary/config/google-drive-copy-scope.credentials
common_env init "$client_json" "$copy_scope_credential" >/dev/null
copy_scope_url=$(common_env begin "$copy_scope_credential" http://127.0.0.1:53683 --copy-tree)
printf '%s\n' "$copy_scope_url" | grep -F 'scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.readonly%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file' >/dev/null
grep -F 'scope=https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file' "$copy_scope_credential.pending" >/dev/null
common_env cancel "$copy_scope_credential" >/dev/null

if printf '%s\n' "$authorization_url" | grep -F 'CLIENT_SECRET' >/dev/null; then
    printf '%s\n' 'client secret leaked into authorization URL' >&2
    exit 1
fi
pending=$credential.pending
[ "$(stat -c %a "$pending")" = 600 ]
state=$(sed -n 's/^state=//p' "$pending")
[ -n "$state" ]

wrong_state_callback=$temporary/wrong-state.callback
printf '%s\n' 'http://127.0.0.1:53682/?code=SHOULD_NOT_EXCHANGE&state=WRONG_STATE' \
    > "$wrong_state_callback"
chmod 600 "$wrong_state_callback"
if common_env complete "$credential" < "$wrong_state_callback" \
    >/dev/null 2>"$temporary/wrong-state.err"
then
    printf '%s\n' 'mismatched OAuth state unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'state did not match' "$temporary/wrong-state.err" >/dev/null
[ -f "$pending" ]
if find "$temporary" -maxdepth 1 -type d -name 'cloud-storage-oauth-complete.*' | grep . >/dev/null; then
    printf '%s\n' 'failed OAuth callback left a temporary directory' >&2
    exit 1
fi

callback=$temporary/callback.url
printf 'http://127.0.0.1:53682/?code=AUTHORIZATION_CODE&state=%s\n' "$state" > "$callback"
chmod 600 "$callback"
exchange_output=$(common_env complete "$credential" < "$callback")
printf '%s\n' "$exchange_output" | grep -F 'authorized_scope=https://www.googleapis.com/auth/drive.readonly' >/dev/null
[ ! -e "$pending" ]
grep -F 'refresh_token=REFRESH_LONG_LIVED' "$credential" >/dev/null
grep -F 'access_token=ACCESS_INITIAL' "$credential" >/dev/null

for secret in GOCSPX-CLIENT_SECRET AUTHORIZATION_CODE REFRESH_LONG_LIVED ACCESS_INITIAL; do
    if grep -F "$secret" "$curl_log" >/dev/null; then
        printf 'OAuth secret leaked into curl argv: %s\n' "$secret" >&2
        exit 1
    fi
done

status_output=$(common_env status "$credential")
printf '%s\n' "$status_output" | grep -F 'authorized=yes' >/dev/null
printf '%s\n' "$status_output" | grep -F 'access_token=fresh' >/dev/null
if printf '%s\n' "$status_output" | grep -E 'ACCESS_|REFRESH_|CLIENT_SECRET' >/dev/null; then
    printf '%s\n' 'OAuth status printed a secret' >&2
    exit 1
fi

fresh_config=$temporary/fresh.curl
common_env curl-config "$credential" "$fresh_config"
grep -F 'Authorization: Bearer ACCESS_INITIAL' "$fresh_config" >/dev/null
initial_form_count=$(wc -l < "$form_log" | tr -d '[:space:]')

sed 's/^access_token_expires_at=.*/access_token_expires_at=1/' "$credential" > "$credential.expired"
chmod 600 "$credential.expired"
mv "$credential.expired" "$credential"
refreshed_config=$temporary/refreshed.curl
common_env curl-config "$credential" "$refreshed_config"
grep -F 'Authorization: Bearer ACCESS_REFRESHED' "$refreshed_config" >/dev/null
grep -F 'access_token=ACCESS_REFRESHED' "$credential" >/dev/null
refreshed_form_count=$(wc -l < "$form_log" | tr -d '[:space:]')
[ "$refreshed_form_count" -gt "$initial_form_count" ]

for secret in REFRESH_LONG_LIVED ACCESS_REFRESHED; do
    if grep -F "$secret" "$curl_log" >/dev/null; then
        printf 'refreshed OAuth secret leaked into curl argv: %s\n' "$secret" >&2
        exit 1
    fi
done

FAKE_REFRESH_ERROR=invalid_grant
export FAKE_REFRESH_ERROR
if common_env curl-config "$credential" "$temporary/revoked.curl" --force-refresh \
    >/dev/null 2>"$temporary/revoked.err"
then
    printf '%s\n' 'revoked refresh token unexpectedly succeeded' >&2
    exit 1
fi
unset FAKE_REFRESH_ERROR
grep -F 'run authorize again' "$temporary/revoked.err" >/dev/null

wrong_credential=$temporary/config/wrong-scope.credentials
common_env init "$client_json" "$wrong_credential" >/dev/null
common_env begin "$wrong_credential" http://127.0.0.1:53683 >/dev/null
wrong_state=$(sed -n 's/^state=//p' "$wrong_credential.pending")
printf 'http://127.0.0.1:53683/?code=WRONG_SCOPE_CODE&state=%s\n' "$wrong_state" > "$temporary/wrong.callback"
FAKE_SCOPE_FAILURE=1
export FAKE_SCOPE_FAILURE
if common_env complete "$wrong_credential" \
    < "$temporary/wrong.callback" >/dev/null 2>"$temporary/scope.err"
then
    printf '%s\n' 'insufficient OAuth scope unexpectedly succeeded' >&2
    exit 1
fi
unset FAKE_SCOPE_FAILURE
grep -F 'did not grant the requested Drive OAuth scope set' "$temporary/scope.err" >/dev/null

android_client_json=$temporary/android-web-client.json
cat > "$android_client_json" <<'EOF_ANDROID_CLIENT'
{
  "web": {
    "client_id": "ANDROID_WEB_CLIENT.apps.googleusercontent.com",
    "client_secret": "GOCSPX-ANDROID_WEB_SECRET",
    "redirect_uris": []
  }
}
EOF_ANDROID_CLIENT
chmod 600 "$android_client_json"

android_credential=$temporary/config/google-drive-android.credentials
android_init=$(common_env init-android "$android_client_json" "$android_credential")
printf '%s\n' "$android_init" | grep -F 'authorized=no' >/dev/null
grep -F 'client_type=android-web' "$android_credential" >/dev/null
grep -F 'client_id=ANDROID_WEB_CLIENT.apps.googleusercontent.com' "$android_credential" >/dev/null

android_stdout=$temporary/android-authorize.stdout
android_stderr=$temporary/android-authorize.stderr
common_env authorize-android "$android_credential" --copy-tree --no-open --timeout 20 \
    >"$android_stdout" 2>"$android_stderr" &
android_pid=$!
attempt=0
while ! grep -F 'ib://google-drive-authorize?' "$android_stdout" >/dev/null 2>&1 && [ "$attempt" -lt 10 ]; do
    if ! kill -0 "$android_pid" >/dev/null 2>&1; then
        wait "$android_pid" || :
        cat "$android_stderr" >&2
        printf '%s\n' 'Android authorization handoff exited before publishing its control URI' >&2
        exit 1
    fi
    sleep 1
    attempt=$((attempt + 1))
done
control_uri=$(sed -n '/^ib:\/\/google-drive-authorize?/p' "$android_stdout" | head -n 1)
[ -n "$control_uri" ]
printf '%s\n' "$control_uri" | grep -F 'client_id=ANDROID_WEB_CLIENT.apps.googleusercontent.com' >/dev/null
printf '%s\n' "$control_uri" | grep -F 'scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.readonly%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file' >/dev/null
android_state=$(printf '%s\n' "$control_uri" | sed -n 's/.*&state=\([^&]*\)&port=.*/\1/p')
android_port=$(printf '%s\n' "$control_uri" | sed -n 's/.*&port=\([0-9][0-9]*\)$/\1/p')
[ -n "$android_state" ] && [ -n "$android_port" ]
/usr/bin/curl --silent --show-error \
    "http://127.0.0.1:$android_port/?code=ANDROID_SERVER_AUTH_CODE&state=$android_state" >/dev/null
wait "$android_pid"
grep -F 'refresh_token=REFRESH_LONG_LIVED' "$android_credential" >/dev/null
grep -F 'access_token=ACCESS_INITIAL' "$android_credential" >/dev/null
grep -Fx 'scope=https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file' "$android_credential" >/dev/null
android_form=$(tail -n 1 "$form_log")
printf '%s\n' "$android_form" | grep -F 'code=ANDROID_SERVER_AUTH_CODE' >/dev/null
printf '%s\n' "$android_form" | grep -F 'redirect_uri=&grant_type=authorization_code' >/dev/null
if printf '%s\n' "$android_form" | grep -F 'code_verifier=' >/dev/null; then
    printf '%s\n' 'Android server-code exchange unexpectedly used the Desktop PKCE verifier' >&2
    exit 1
fi
for secret in GOCSPX-ANDROID_WEB_SECRET ANDROID_SERVER_AUTH_CODE; do
    if grep -F "$secret" "$curl_log" >/dev/null; then
        printf 'Android OAuth secret leaked into curl argv: %s\n' "$secret" >&2
        exit 1
    fi
done

fake_handoff=$temporary/fake-authorization-handoff.grease
cat > "$fake_handoff" <<'EOF_FAKE_HANDOFF'
set -eu
[ "${1:-}" = listen ] || exit 64
shift
[ "$#" -eq 4 ] || exit 64
pending_file=$1
offer_file=$2
result_file=$3
timeout_seconds=$4
case $timeout_seconds in ''|*[!0-9]*) exit 64 ;; esac
state=$(sed -n 's/^state=//p' "$pending_file")
[ -n "$state" ] || exit 65
umask 077
cat > "$offer_file" <<'EOF_OFFER'
schema=google-drive-authorization-handoff-v1
adapter=fake
control_name=reply
control_value=fake-result
EOF_OFFER
chmod 600 "$offer_file"
{
    printf '%s\n' 'code=ADAPTER_SERVER_AUTH_CODE'
    if [ "${FAKE_HANDOFF_WRONG_STATE:-0}" = 1 ]; then
        printf '%s\n' 'state=WRONG_ADAPTER_STATE'
    else
        printf 'state=%s\n' "$state"
    fi
} > "$result_file"
chmod 600 "$result_file"
EOF_FAKE_HANDOFF
chmod 600 "$fake_handoff"

adapter_credential=$temporary/config/google-drive-android-adapter.credentials
common_env init-android "$android_client_json" "$adapter_credential" >/dev/null
export GOOGLE_DRIVE_AUTHORIZATION_HANDOFF=$fake_handoff
adapter_stdout=$temporary/adapter-authorize.stdout
adapter_stderr=$temporary/adapter-authorize.stderr
common_env authorize-android "$adapter_credential" --no-open --timeout 20 \
    >"$adapter_stdout" 2>"$adapter_stderr"
unset GOOGLE_DRIVE_AUTHORIZATION_HANDOFF
grep -F 'ib://google-drive-authorize?' "$adapter_stdout" >/dev/null
grep -F '&reply=fake-result' "$adapter_stdout" >/dev/null
if grep -F '&port=' "$adapter_stdout" >/dev/null; then
    printf '%s\n' 'semantic handoff test unexpectedly required a loopback port' >&2
    exit 1
fi
grep -F 'authorization_handoff_adapter=fake' "$adapter_stderr" >/dev/null
grep -F 'refresh_token=REFRESH_LONG_LIVED' "$adapter_credential" >/dev/null
grep -F 'access_token=ACCESS_INITIAL' "$adapter_credential" >/dev/null
adapter_form=$(tail -n 1 "$form_log")
printf '%s\n' "$adapter_form" | grep -F 'code=ADAPTER_SERVER_AUTH_CODE' >/dev/null

wrong_adapter_credential=$temporary/config/google-drive-android-wrong-adapter.credentials
common_env init-android "$android_client_json" "$wrong_adapter_credential" >/dev/null
export GOOGLE_DRIVE_AUTHORIZATION_HANDOFF=$fake_handoff
export FAKE_HANDOFF_WRONG_STATE=1
if common_env authorize-android "$wrong_adapter_credential" --no-open --timeout 20 \
    >"$temporary/wrong-adapter.stdout" 2>"$temporary/wrong-adapter.stderr"
then
    printf '%s\n' 'wrong-state Android handoff unexpectedly succeeded' >&2
    exit 1
fi
unset FAKE_HANDOFF_WRONG_STATE
unset GOOGLE_DRIVE_AUTHORIZATION_HANDOFF
grep -F 'Android authorization state did not match the pending request' \
    "$temporary/wrong-adapter.stderr" >/dev/null
[ -f "$wrong_adapter_credential.pending" ]

loop_pending=$temporary/loop.pending
loop_port=$temporary/loop.port
loop_result=$temporary/loop.result
printf '%s\n' 'state=LOOPBACK_STATE' > "$loop_pending"
chmod 600 "$loop_pending"
"$GOOGLE_OAUTH_LOOPBACK" listen "$loop_pending" "$loop_port" "$loop_result" 10 &
loop_pid=$!
attempt=0
while [ ! -f "$loop_port" ] && [ "$attempt" -lt 10 ]; do sleep 1; attempt=$((attempt + 1)); done
[ -f "$loop_port" ]
port=$(sed -n '1p' "$loop_port")
/usr/bin/curl --silent --show-error \
    "http://127.0.0.1:$port/?code=LOOPBACK_CODE&state=LOOPBACK_STATE" >/dev/null
wait "$loop_pid"
grep -F 'code=LOOPBACK_CODE' "$loop_result" >/dev/null
[ "$(stat -c %a "$loop_result")" = 600 ]

chmod 644 "$credential"
if common_env status "$credential" >/dev/null 2>"$temporary/mode.err"; then
    printf '%s\n' 'world-readable credential unexpectedly accepted' >&2
    exit 1
fi
grep -F 'must not be accessible by group or other users' "$temporary/mode.err" >/dev/null

printf '%s\n' 'Google Drive OAuth PKCE, private storage, refresh, revocation, scope, semantic Android handoff, and loopback adapter contracts pass'
