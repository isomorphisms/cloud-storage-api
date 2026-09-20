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
        printf '%s\n' '{"access_token":"ACCESS_INITIAL","expires_in":3600,"refresh_token":"REFRESH_LONG_LIVED","scope":"https://www.googleapis.com/auth/drive.readonly","token_type":"Bearer"}' > "$output"
    fi
    printf '%s' 200
elif grep -F 'grant_type=refresh_token' "$form" >/dev/null; then
    if [ "${FAKE_REFRESH_ERROR:-}" = invalid_grant ]; then
        printf '%s\n' '{"error":"invalid_grant","error_description":"revoked"}' > "$output"
        printf '%s' 400
        exit 22
    fi
    printf '%s\n' '{"access_token":"ACCESS_REFRESHED","expires_in":3600,"scope":"https://www.googleapis.com/auth/drive.readonly","token_type":"Bearer"}' > "$output"
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
if printf '%s\n' "$authorization_url" | grep -F 'CLIENT_SECRET' >/dev/null; then
    printf '%s\n' 'client secret leaked into authorization URL' >&2
    exit 1
fi
pending=$credential.pending
[ "$(stat -c %a "$pending")" = 600 ]
state=$(sed -n 's/^state=//p' "$pending")
[ -n "$state" ]

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
grep -F 'did not grant the required Drive read-only scope' "$temporary/scope.err" >/dev/null

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

printf '%s\n' 'Google Drive OAuth PKCE, private storage, refresh, revocation, scope, and loopback contracts pass'
