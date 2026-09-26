module google_drive_api;

import core.sys.posix.sys.stat : chmod, S_IRUSR, S_IWUSR;
import std.algorithm : startsWith;
import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, getSize, mkdirRecurse, read, readText, remove, rename, write;
import std.format : formattedWrite, format;
import std.json : JSONValue, parseJSON;
import std.net.curl : HTTP, CurlException;
import std.path : dirName;
import std.process : environment;
import std.stdio : File, stdin, stdout, stderr;
import std.string : indexOf, split, strip, toStringz;

private enum api_base_default = "https://www.googleapis.com/drive/v3/";
private enum upload_base_default = "https://www.googleapis.com/upload/drive/v3/";

private enum method_surface = import("google-drive-v3-methods.tsv");

private struct DriveMethod {
    string id;
    string http_method;
    string path;
    bool has_json_body;
    bool has_resumable_upload;
    bool deprecated_;
}

private struct Pair {
    string name;
    string value;
}

private struct Response {
    ushort status;
    string[string] headers;
    ubyte[] body;
}

private noreturn fail(string message) {
    throw new Exception(message);
}

private DriveMethod[] methods() {
    DriveMethod[] result;
    foreach (line; method_surface.split('\n')) {
        if (line.length == 0) continue;
        auto columns = line.split('\t');
        enforce(columns.length == 6, "invalid embedded Drive method row");
        result ~= DriveMethod(
            columns[0],
            columns[1],
            columns[2],
            columns[3] == "json",
            columns[4] == "resumable",
            columns[5] == "deprecated"
        );
    }
    return result;
}

private DriveMethod lookup_method(string requested) {
    foreach (method; methods()) {
        if (method.id == requested) return method;
    }
    fail("unknown pinned Drive method: " ~ requested);
}

private Pair parse_pair(string raw, string option_name) {
    auto separator = raw.indexOf('=');
    if (separator < 0) fail(option_name ~ " needs NAME=VALUE: " ~ raw);
    auto name = raw[0 .. separator];
    if (name.length == 0) fail(option_name ~ " name must not be empty");
    return Pair(name, raw[separator + 1 .. $]);
}

private bool is_unreserved(ubyte value) {
    return (value >= 'A' && value <= 'Z') ||
           (value >= 'a' && value <= 'z') ||
           (value >= '0' && value <= '9') ||
           value == '-' || value == '.' || value == '_' || value == '~';
}

private string encode_component(string input) {
    auto encoded = appender!string;
    foreach (ubyte value; cast(const(ubyte)[]) input) {
        if (is_unreserved(value)) {
            encoded.put(cast(char) value);
        } else {
            formattedWrite(encoded, "%%%02X", value);
        }
    }
    return encoded.data;
}

private string replace_path_parameter(string path, Pair pair, string method_id) {
    auto placeholder = "{" ~ pair.name ~ "}";
    auto position = path.indexOf(placeholder);
    if (position < 0) fail("method " ~ method_id ~ " has no path parameter named " ~ pair.name);
    return path[0 .. position] ~ encode_component(pair.value) ~ path[position + placeholder.length .. $];
}

private string build_query(Pair[] pairs) {
    if (pairs.length == 0) return "";
    auto result = appender!string;
    result.put('?');
    foreach (index, pair; pairs) {
        if (index != 0) result.put('&');
        result.put(encode_component(pair.name));
        result.put('=');
        result.put(encode_component(pair.value));
    }
    return result.data;
}

private HTTP.Method http_method(string name) {
    switch (name) {
        case "GET": return HTTP.Method.get;
        case "POST": return HTTP.Method.post;
        case "PUT": return HTTP.Method.put;
        case "PATCH": return HTTP.Method.patch;
        case "DELETE": return HTTP.Method.del;
        default: fail("unsupported HTTP method in pinned Drive surface: " ~ name);
    }
}

private string access_token() {
    auto token = environment.get("GOOGLE_ACCESS_TOKEN", "").strip;
    if (token.length == 0) {
        auto path = environment.get("GOOGLE_ACCESS_TOKEN_FILE", "");
        if (path.length != 0) token = readText(path).strip;
    }
    if (token.length == 0) fail("set GOOGLE_ACCESS_TOKEN or GOOGLE_ACCESS_TOKEN_FILE");
    return token.idup;
}

private void add_common_headers(ref HTTP http, string token) {
    http.addRequestHeader("Authorization", "Bearer " ~ token);
    auto resource_keys = environment.get("GOOGLE_DRIVE_RESOURCE_KEYS", "");
    if (resource_keys.length != 0) {
        http.addRequestHeader("X-Goog-Drive-Resource-Keys", resource_keys);
    }
}

private Response request_memory(
    string url,
    HTTP.Method method,
    string token,
    const(ubyte)[] body = null,
    string content_type = "",
    string[string] extra_headers = null
) {
    auto response_body = appender!(ubyte[]);
    string[string] response_headers;
    ushort status;

    auto http = HTTP(url);
    http.method = method;
    http.maxRedirects = 5;
    add_common_headers(http, token);
    foreach (name, value; extra_headers) http.addRequestHeader(name, value);

    if (body !is null) {
        http.setPostData(body, content_type.length == 0 ? "application/octet-stream" : content_type);
        http.method = method;
    } else if (method == HTTP.Method.post || method == HTTP.Method.put || method == HTTP.Method.patch) {
        http.contentLength = 0;
    }

    http.onReceiveStatusLine = (HTTP.StatusLine line) { status = line.code; };
    http.onReceiveHeader = (in char[] key, in char[] value) {
        if (key.length != 0) response_headers[key.idup] = value.idup.strip.idup;
    };
    http.onReceive = (ubyte[] data) {
        response_body.put(data);
        return data.length;
    };
    http.perform();

    return Response(status, response_headers, response_body.data);
}

private void request_to_stdout(
    string url,
    HTTP.Method method,
    string token,
    const(ubyte)[] body = null,
    string content_type = ""
) {
    ushort status;
    auto error_body = appender!(ubyte[]);

    auto http = HTTP(url);
    http.method = method;
    http.maxRedirects = 5;
    add_common_headers(http, token);
    if (body !is null) {
        http.setPostData(body, content_type.length == 0 ? "application/octet-stream" : content_type);
        http.method = method;
    } else if (method == HTTP.Method.post || method == HTTP.Method.put || method == HTTP.Method.patch) {
        http.contentLength = 0;
    }

    http.onReceiveStatusLine = (HTTP.StatusLine line) { status = line.code; };
    http.onReceive = (ubyte[] data) {
        if (status >= 400) error_body.put(data);
        else stdout.rawWrite(data);
        return data.length;
    };
    http.perform();

    if (status < 200 || status >= 300) {
        if (error_body.data.length != 0) stderr.rawWrite(error_body.data);
        fail(format("Drive request failed with HTTP %s", status));
    }
}

private const(ubyte)[] read_body(string path) {
    if (path == "-") {
        auto content = appender!(ubyte[]);
        ubyte[64 * 1024] buffer;
        while (true) {
            auto chunk = stdin.rawRead(buffer[]);
            if (chunk.length == 0) break;
            content.put(chunk);
        }
        return content.data;
    }
    if (!exists(path)) fail("JSON body file not found: " ~ path);
    return cast(const(ubyte)[]) read(path);
}

private string header_value(const Response response, string wanted) {
    foreach (name, value; response.headers) {
        if (name.length == wanted.length) {
            bool equal = true;
            foreach (index; 0 .. name.length) {
                char left = name[index];
                char right = wanted[index];
                if (left >= 'A' && left <= 'Z') left = cast(char)(left + ('a' - 'A'));
                if (right >= 'A' && right <= 'Z') right = cast(char)(right + ('a' - 'A'));
                if (left != right) { equal = false; break; }
            }
            if (equal) return value;
        }
    }
    return "";
}

private void ensure_parent_directory(string path) {
    auto parent = dirName(path);
    if (parent.length != 0 && parent != ".") mkdirRecurse(parent);
}

private JSONValue session_json(
    DriveMethod method,
    string api_path,
    string media_file,
    string media_type,
    ulong media_size,
    string session_uri
) {
    JSONValue[string] object;
    object["method"] = JSONValue(method.id);
    object["path"] = JSONValue(api_path);
    object["media"] = JSONValue(media_file);
    object["media_type"] = JSONValue(media_type);
    object["media_size"] = JSONValue(cast(long) media_size);
    object["session_uri"] = JSONValue(session_uri);
    return JSONValue(object);
}

private void write_session(
    string path,
    DriveMethod method,
    string api_path,
    string media_file,
    string media_type,
    ulong media_size,
    string session_uri
) {
    ensure_parent_directory(path);
    auto temporary = path ~ ".tmp";
    write(
        temporary,
        session_json(method, api_path, media_file, media_type, media_size, session_uri).toString() ~ "\n"
    );
    chmod(temporary.toStringz, S_IRUSR | S_IWUSR);
    rename(temporary, path);
}

private string read_session(
    string path,
    DriveMethod method,
    string api_path,
    string media_file,
    string media_type,
    ulong media_size
) {
    if (!exists(path)) return "";
    auto value = parseJSON(readText(path));
    auto object = value.object;

    if (object["method"].str != method.id ||
        object["path"].str != api_path ||
        object["media"].str != media_file ||
        object["media_type"].str != media_type ||
        object["media_size"].integer.to!ulong != media_size) {
        fail("resumable session file does not match this upload: " ~ path);
    }
    return object["session_uri"].str;
}

private ulong next_upload_offset(const Response response, ulong media_size) {
    if (response.status == 200 || response.status == 201) return media_size;
    if (response.status != 308) fail(format("resumable upload status failed with HTTP %s", response.status));

    auto range = header_value(response, "Range");
    if (range.length == 0) return 0;
    if (!range.startsWith("bytes=0-")) fail("unexpected resumable upload Range header: " ~ range);
    auto last = range[8 .. $].to!ulong;
    if (last >= media_size) fail("resumable upload Range exceeds media size");
    return last + 1;
}

private Response query_upload_status(string session_uri, string token, ulong media_size) {
    string[string] headers;
    headers["Content-Range"] = "bytes */" ~ media_size.to!string;
    return request_memory(session_uri, HTTP.Method.put, token, null, "", headers);
}

private Response upload_from_offset(
    string session_uri,
    string token,
    string media_file,
    string media_type,
    ulong media_size,
    ulong offset
) {
    auto response_body = appender!(ubyte[]);
    string[string] response_headers;
    ushort status;
    auto media = File(media_file, "rb");
    media.seek(offset);
    auto remaining = media_size - offset;

    auto http = HTTP(session_uri);
    http.method = HTTP.Method.put;
    http.maxRedirects = 5;
    add_common_headers(http, token);
    http.addRequestHeader("Content-Type", media_type);
    http.contentLength = remaining;
    if (media_size != 0) {
        http.addRequestHeader(
            "Content-Range",
            "bytes " ~ offset.to!string ~ "-" ~ (media_size - 1).to!string ~ "/" ~ media_size.to!string
        );
    }

    http.onReceiveStatusLine = (HTTP.StatusLine line) { status = line.code; };
    http.onReceiveHeader = (in char[] key, in char[] value) {
        if (key.length != 0) response_headers[key.idup] = value.idup.strip.idup;
    };
    http.onSend = (void[] target) {
        if (target.length == 0) return cast(size_t) 0;
        auto bytes = cast(ubyte[]) target;
        auto chunk = media.rawRead(bytes);
        return chunk.length;
    };
    http.onReceive = (ubyte[] data) {
        response_body.put(data);
        return data.length;
    };
    http.perform();
    return Response(status, response_headers, response_body.data);
}

private string start_upload_session(
    DriveMethod method,
    string api_path,
    Pair[] query_pairs,
    const(ubyte)[] metadata,
    string token,
    string media_type,
    ulong media_size
) {
    query_pairs ~= Pair("uploadType", "resumable");
    auto upload_base = environment.get("GOOGLE_DRIVE_UPLOAD_BASE_URL", upload_base_default);
    string[string] headers;
    headers["X-Upload-Content-Type"] = media_type;
    headers["X-Upload-Content-Length"] = media_size.to!string;
    auto body = metadata.length == 0 ? cast(const(ubyte)[]) "{}" : metadata;

    auto response = request_memory(
        upload_base ~ api_path ~ build_query(query_pairs),
        http_method(method.http_method),
        token,
        body,
        "application/json; charset=UTF-8",
        headers
    );
    if (response.status < 200 || response.status >= 300) {
        fail(format("resumable upload initiation failed with HTTP %s", response.status));
    }
    auto location = header_value(response, "Location");
    if (location.length == 0) fail("resumable upload did not return a Location header");
    return location;
}

private void upload_resumable(
    DriveMethod method,
    string api_path,
    Pair[] query_pairs,
    string body_path,
    string media_file,
    string media_type,
    string session_file,
    string token
) {
    if (!method.has_resumable_upload) {
        fail(method.id ~ " does not advertise media upload in the pinned discovery document");
    }
    if (session_file.length == 0) {
        fail("--session-file is required with --media so resumable state survives failure");
    }
    if (!exists(media_file)) fail("media file not found: " ~ media_file);

    auto media_size = getSize(media_file);
    const(ubyte)[] metadata;
    if (body_path.length != 0) metadata = read_body(body_path);

    auto session_uri = read_session(session_file, method, api_path, media_file, media_type, media_size);
    ulong offset;

    if (session_uri.length == 0) {
        session_uri = start_upload_session(
            method, api_path, query_pairs.dup, metadata, token, media_type, media_size
        );
        write_session(session_file, method, api_path, media_file, media_type, media_size, session_uri);
        offset = 0;
    } else {
        auto status = query_upload_status(session_uri, token, media_size);
        if (status.status == 404) {
            remove(session_file);
            session_uri = start_upload_session(
                method, api_path, query_pairs.dup, metadata, token, media_type, media_size
            );
            write_session(session_file, method, api_path, media_file, media_type, media_size, session_uri);
            offset = 0;
        } else {
            offset = next_upload_offset(status, media_size);
            if (offset == media_size) {
                if (status.body.length != 0) stdout.rawWrite(status.body);
                remove(session_file);
                return;
            }
        }
    }

    ulong previous_offset = ulong.max;
    while (offset < media_size || media_size == 0) {
        if (offset == previous_offset) fail("resumable upload made no forward progress");
        previous_offset = offset;

        Response response;
        try {
            response = upload_from_offset(session_uri, token, media_file, media_type, media_size, offset);
        } catch (CurlException error) {
            stderr.writeln("resumable upload interrupted; session retained at ", session_file);
            throw error;
        }

        if (response.status == 200 || response.status == 201) {
            stdout.rawWrite(response.body);
            remove(session_file);
            return;
        }
        if (response.status == 308) {
            offset = next_upload_offset(response, media_size);
            continue;
        }
        if (response.status == 404) {
            fail(
                "resumable upload session expired; rerun after removing the saved session file: " ~
                session_file
            );
        }
        fail(format("resumable upload failed with HTTP %s", response.status));
    }
}

private void usage() {
    stdout.write(
`usage:
  google-drive-api-d methods
  google-drive-api-d surface
  google-drive-api-d METHOD [OPTIONS]

METHOD is a pinned Google Drive v3 discovery method ID. The leading "drive."
may be omitted.

Options:
  --path NAME=VALUE
  --query NAME=VALUE
  --body FILE
  --media FILE
  --media-type MIME_TYPE
  --session-file FILE

Environment:
  GOOGLE_ACCESS_TOKEN
  GOOGLE_ACCESS_TOKEN_FILE
  GOOGLE_DRIVE_RESOURCE_KEYS

The D implementation uses the pinned 64-method Drive v3 surface and keeps
provider IDs, query parameters, request bodies, uploads, and response bytes
provider-native.
`
    );
}

int main(string[] arguments) {
    try {
        if (arguments.length < 2 || arguments[1] == "-h" || arguments[1] == "--help") {
            usage();
            return 0;
        }
        if (arguments[1] == "methods") {
            foreach (method; methods()) stdout.writeln(method.id);
            return 0;
        }
        if (arguments[1] == "surface") {
            stdout.write(method_surface);
            return 0;
        }

        auto requested_method = arguments[1];
        if (!requested_method.startsWith("drive.")) requested_method = "drive." ~ requested_method;
        auto method = lookup_method(requested_method);
        auto api_path = method.path;
        Pair[] query_pairs;
        string body_path;
        string media_file;
        string media_type = "application/octet-stream";
        string session_file;

        for (size_t index = 2; index < arguments.length;) {
            auto option = arguments[index];
            if (option == "--path" || option == "--query" || option == "--body" ||
                option == "--media" || option == "--media-type" || option == "--session-file") {
                if (index + 1 >= arguments.length) fail(option ~ " needs a value");
                auto value = arguments[index + 1];
                if (option == "--path") {
                    api_path = replace_path_parameter(api_path, parse_pair(value, option), method.id);
                } else if (option == "--query") {
                    query_pairs ~= parse_pair(value, option);
                } else if (option == "--body") {
                    body_path = value;
                } else if (option == "--media") {
                    media_file = value;
                } else if (option == "--media-type") {
                    media_type = value;
                } else {
                    session_file = value;
                }
                index += 2;
                continue;
            }
            if (option == "-h" || option == "--help") {
                usage();
                return 0;
            }
            fail("unknown option: " ~ option);
        }

        if (api_path.indexOf('{') >= 0) {
            fail("missing --path value for " ~ method.id ~ " path " ~ api_path);
        }
        if (!method.has_json_body && body_path.length != 0) {
            fail(method.id ~ " has no request body in the pinned discovery document");
        }
        if (media_file.length == 0 &&
            (session_file.length != 0 || media_type != "application/octet-stream")) {
            fail("--media-type and --session-file require --media");
        }

        auto token = access_token();
        if (media_file.length != 0) {
            upload_resumable(
                method, api_path, query_pairs, body_path, media_file, media_type, session_file, token
            );
            return 0;
        }

        const(ubyte)[] body;
        if (body_path.length != 0) body = read_body(body_path);
        auto api_base = environment.get("GOOGLE_DRIVE_API_BASE_URL", api_base_default);
        request_to_stdout(
            api_base ~ api_path ~ build_query(query_pairs),
            http_method(method.http_method),
            token,
            body,
            body_path.length == 0 ? "" : "application/json"
        );
        return 0;
    } catch (Exception error) {
        if (error.msg.length != 0) stderr.writeln(error.msg);
        return 2;
    }
}
