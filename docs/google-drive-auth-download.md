# Google Drive authentication and stored-byte download

This path uses the documented Google OAuth installed-application flow and the
Drive v3 HTTP API directly. It does not invoke `rclone`, a generated Google SDK,
or a heavyweight client library.

The implementation follows these Google references, checked on 2026-09-20:

- <https://developers.google.com/identity/protocols/oauth2/native-app>
- <https://developers.google.com/identity/protocols/oauth2/resources/best-practices>
- <https://developers.google.com/workspace/drive/api/guides/api-specific-auth>
- <https://developers.google.com/workspace/drive/api/guides/manage-downloads>

The pinned discovery mirror remains normative for the Drive method and file
schema used by this repository.

## One-time Google setup

1. In a user-owned Google Cloud project, enable Google Drive API v3.
2. Configure the OAuth consent screen and add the intended account as a test
   user when the application remains in testing.
3. Create an OAuth client of type **Desktop app** and download its client JSON.
   The shell client uses the desktop installed-app PKCE flow and a random
   `127.0.0.1` callback port. It does not use the removed out-of-band flow.

The OAuth helper requests only:

```text
https://www.googleapis.com/auth/drive.readonly
```

`drive.file` is narrower but cannot discover an existing Takeout object that
the application did not create or open. The read-only Drive scope is therefore
the least privilege that satisfies this workflow. It does not authorize the
write methods exposed by the separate thin API command.

## Build or install the small native helpers

The product commands are Grease. Small C helpers own boundaries that should not
be improvised in shell: the loopback callback socket, fixed-width file
offset/fsync operations, and the already-established bounded ZIP parser.

From a checkout, with an explicit installation directory:

```sh
repo=/absolute/path/to/cloud-storage-api
program_directory=/absolute/path/to/private/program-directory

mkdir -p "$program_directory"
cc -std=c99 -Wall -Wextra -Werror -O2 \
  "$repo/commands/google-oauth-loopback.c" \
  -o "$program_directory/google-oauth-loopback"
cc -std=c99 -Wall -Wextra -Werror -O2 \
  "$repo/commands/google-drive-download-state.c" \
  -o "$program_directory/google-drive-download-state"
cc -std=c99 -Wall -Wextra -Werror -O2 \
  "$repo/commands/zip-central-directory.c" \
  -o "$program_directory/zip-central-directory"
install -m 755 \
  "$repo/commands/google-drive-auth.grease" \
  "$repo/commands/google-drive-api.grease" \
  "$repo/commands/google-drive-files.grease" \
  "$repo/commands/google-drive-download.grease" \
  "$repo/commands/google-drive-zip-inventory.grease" \
  "$program_directory/"
```

Put that explicit program directory in `PATH`, or set the helper path variables
documented by each command. These commands resolve their companion Grease files
from the script directory and do not depend on the caller's current directory.

## Authorize once and refresh automatically

Import Google's downloaded client file into the durable private plain-text
credential, then authorize:

```sh
google-drive-auth init \
  /explicit/path/to/client_secret.json \
  /explicit/private/path/google-drive.credentials \
  --create-parent

google-drive-auth authorize \
  /explicit/private/path/google-drive.credentials
```

`authorize` generates a fresh PKCE verifier/challenge and state value, binds a
random IPv4 loopback port, opens the system browser when possible, validates the
returned state, exchanges the code, and stores the refresh/access tokens in the
mode-0600 credential. Authorization codes and tokens are sent in private files
or request bodies, not process arguments.

For a remote/headless shell, use the explicit two-step form. The callback URL
is read from stdin so its code is not an argument:

```sh
google-drive-auth begin \
  /explicit/private/path/google-drive.credentials \
  http://127.0.0.1:53682 \
  > /explicit/private/path/authorization-url

# Open the saved URL, then save the complete browser callback URL privately.
chmod 600 /explicit/private/path/callback-url
google-drive-auth complete \
  /explicit/private/path/google-drive.credentials \
  < /explicit/private/path/callback-url
```

### Android phone handoff through IB

Google blocks OAuth authorization pages in embedded WebViews. The phone path
therefore does not send the Google authorization endpoint to IB's WebView.
Instead, IB invokes Google Identity Services and returns only the one-time
server authorization code through a narrow result-handoff boundary.

The OAuth state machine does not own the handoff transport. The current
`google-drive-authorization-handoff.grease` adapter still uses the existing
random IPv4 loopback receiver underneath, but it publishes that as one
non-secret control name/value. A later Binder/ParcelFileDescriptor,
ContentProvider, Unix-domain-socket, or other phone adapter can replace that
lowering without changing pending OAuth state, Google Identity Services, token
exchange, or durable credential storage.

In the same Google Cloud project, configure:

- an Android OAuth client for package `org.isomorphisms.ib.webview`, using the
  SHA-1 of the stable private certificate that signs the installed IB APK;
- a Web application OAuth client for the server/offline authorization code.
  Download that Web client JSON. No browser redirect URI is needed for this
  local server-code exchange.

Do not register a public or throwaway debug signing key for the Android client.
The signing identity is part of the OAuth client identity.

Import the Web client and start the private handoff:

```sh
google-drive-auth init-android \
  /explicit/path/to/web-client-secret.json \
  /explicit/private/path/google-drive.credentials \
  --create-parent

google-drive-auth authorize-android \
  /explicit/private/path/google-drive.credentials
```

`authorize-android` creates fresh durable pending state, starts the configured
result-handoff adapter, and waits for a private result. The adapter publishes a
small offer:

```text
schema=google-drive-authorization-handoff-v1
adapter=<adapter name>
control_name=<one non-secret query field>
control_value=<one non-secret value>
```

The OAuth command validates that offer and adds the control name/value to the
private `ib://google-drive-authorize?...` URI. It does not interpret the value
as a TCP port. The current loopback adapter happens to publish
`control_name=port`; that is adapter vocabulary rather than OAuth vocabulary.

On Termux the command sends the control URI directly to IB with
`termux-open-url`; if that helper is unavailable, it prints the URI. The URI
contains only the Web client ID, requested read-only scope, state, and the
adapter's non-secret control field. It contains no client secret, authorization
code, refresh token, or bearer token.

IB must accept only the exact Drive read-only scope, obtain a server auth code
through Google Identity Services, and return it through the offered handoff with
the same state. The shell exchanges that code using the imported Web client,
requires a refresh token and the Drive read-only scope, then writes the same
mode-0600 credential format used by the Desktop flow.

The adapter is selected with `GOOGLE_DRIVE_AUTHORIZATION_HANDOFF` when an
explicit Grease program is being tested. The default is the sibling
`google-drive-authorization-handoff.grease`. `GOOGLE_OAUTH_LOOPBACK` remains
the low-level helper used by that default adapter and by the Desktop flow.

The Android flow is deliberately separate from the Desktop PKCE path above.
It does not make successful Android authorization evidence a claim about the
WebView, and it does not weaken the existing Desktop loopback contract.
Ordinary commands then need only the credential location:

```sh
export GOOGLE_DRIVE_CREDENTIAL_FILE=/explicit/private/path/google-drive.credentials
```

They refresh before expiry. A multi-request range operation also refreshes once
and retries when Drive returns HTTP 401. Revoked refresh tokens stop with an
instruction to authorize again. The credential, pending state, curl
configuration, and token response files are private and must never be committed.

## Locate the exact Takeout object

Drive file ID is the identity. Search by metadata, then retain the returned ID:

```sh
google-drive-files list \
  --query "name = 'takeout-20260505T145639Z-3-001.zip' and trashed = false"

google-drive-files get DRIVE_FILE_ID
```

For the known object, verify that metadata reports exactly `7,754,047,385`
bytes before treating it as the intended archive. A name match alone is not an
identity proof. `files.list` still exposes `nextPageToken`; callers must follow
it with `--page` when a broad query is paginated.

## Restartable direct download to an explicit destination

For the phone, first verify the removable mount on that device. Then supply the
SD-backed destination itself; no checkout location is assumed:

```sh
google-drive-download DRIVE_FILE_ID \
  /storage/4A21-0000/Android/data/com.termux/files/takeout-20260505T145639Z-3-001.zip \
  --create-parent
```

The command:

- fetches ID, byte length, provider version, modification time, download
  capability, and the strongest Drive checksum available;
- keeps the partial payload and each bounded segment beside the destination,
  so a multi-gigabyte file is not staged through internal `HOME`, `PREFIX`,
  `TMPDIR`, or the source checkout;
- requires HTTP 206, exact `Content-Range`, exact response length, and curl 8.4
  or newer's running `--max-filesize` limit;
- fsyncs every appended segment before atomically advancing the small sidecar;
- truncates an uncommitted crash tail back to the last durable byte boundary,
  but rejects a partial shorter than its state;
- refuses remote identity, size, version, modification-time, or checksum drift;
- verifies final size and the strongest provider checksum available, records a
  local SHA-256, then durably renames the partial file into place;
- refuses an unrelated existing destination and never deletes the Drive source.

The default sidecars are:

```text
DESTINATION.google-drive.partial
DESTINATION.google-drive.state
DESTINATION.google-drive.receipt.ndjson
```

The payload-bearing partial and range segment are always adjacent to
`DESTINATION`. `--state-file` and `--receipt-file` may move only the small
metadata sidecars.

## Bounded inventory is a different workflow

To inventory or select members without downloading all 7.75 GB, use the ranged
ZIP command with the same credential:

```sh
google-drive-zip-inventory DRIVE_FILE_ID \
  > /explicit/path/takeout-inventory.ndjson
```

That remains issue #7's inventory path. Deterministic local and fake-Drive
stages have passed. A real credential, real Drive ZIP, actual Takeout inventory,
selected-member extraction, and physical-phone execution remain independent
evidence boundaries until their receipts exist.
