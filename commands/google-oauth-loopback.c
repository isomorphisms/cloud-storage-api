/*
 * Minimal loopback receiver for the Google installed-application OAuth flow.
 *
 * Grease owns the OAuth state machine and token exchange.  This helper only
 * binds an IPv4 loopback port, validates the returned state value, and writes
 * the authorization code to a mode-0600 file.  It never performs provider
 * requests and never prints an authorization code.
 */
#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define REQUEST_LIMIT 32768u
#define VALUE_LIMIT 16384u

static void die(const char *message) {
    fprintf(stderr, "%s\n", message);
    exit(2);
}

static void die_errno(const char *message) {
    perror(message);
    exit(2);
}

static void write_all(int fd, const char *data, size_t length) {
    while (length) {
        ssize_t written = write(fd, data, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            die_errno("write");
        }
        data += (size_t)written;
        length -= (size_t)written;
    }
}

static char *read_state(const char *path) {
    FILE *input = fopen(path, "r");
    if (!input) die_errno(path);

    char *line = NULL;
    size_t capacity = 0;
    char *state = NULL;
    while (getline(&line, &capacity, input) >= 0) {
        if (strncmp(line, "state=", 6) != 0) continue;
        if (state) die("OAuth pending file has duplicate state fields");
        char *value = line + 6;
        value[strcspn(value, "\r\n")] = '\0';
        if (!*value) die("OAuth pending file has an empty state field");
        state = strdup(value);
        if (!state) die("out of memory");
    }
    free(line);
    if (fclose(input) != 0) die_errno(path);
    if (!state) die("OAuth pending file has no state field");
    return state;
}

static int hex_value(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static char *decode_component(const char *start, size_t length) {
    if (length > VALUE_LIMIT) die("OAuth callback field is too long");
    char *decoded = malloc(length + 1);
    if (!decoded) die("out of memory");

    size_t output = 0;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)start[i];
        if (c == '%') {
            if (i + 2 >= length) die("OAuth callback has malformed percent encoding");
            int high = hex_value((unsigned char)start[i + 1]);
            int low = hex_value((unsigned char)start[i + 2]);
            if (high < 0 || low < 0) die("OAuth callback has malformed percent encoding");
            c = (unsigned char)((high << 4) | low);
            i += 2;
        } else if (c == '+') {
            c = ' ';
        }
        if (c == 0 || c == '\r' || c == '\n')
            die("OAuth callback field contains a forbidden control byte");
        decoded[output++] = (char)c;
    }
    decoded[output] = '\0';
    return decoded;
}

typedef struct {
    char *code;
    char *state;
    char *error;
} Callback;

static void set_once(char **slot, char *value, const char *name) {
    if (*slot) {
        free(value);
        fprintf(stderr, "OAuth callback repeats %s\n", name);
        exit(2);
    }
    *slot = value;
}

static Callback parse_callback(const char *text) {
    const char *query = strchr(text, '?');
    if (!query) die("OAuth callback has no query string");
    ++query;
    const char *fragment = strchr(query, '#');
    const char *end = fragment ? fragment : text + strlen(text);

    Callback callback = {0};
    const char *cursor = query;
    while (cursor <= end) {
        const char *ampersand = memchr(cursor, '&', (size_t)(end - cursor));
        const char *pair_end = ampersand ? ampersand : end;
        const char *equals = memchr(cursor, '=', (size_t)(pair_end - cursor));
        if (equals) {
            char *name = decode_component(cursor, (size_t)(equals - cursor));
            char *value = decode_component(equals + 1, (size_t)(pair_end - equals - 1));
            if (strcmp(name, "code") == 0) set_once(&callback.code, value, "code");
            else if (strcmp(name, "state") == 0) set_once(&callback.state, value, "state");
            else if (strcmp(name, "error") == 0) set_once(&callback.error, value, "error");
            else free(value);
            free(name);
        }
        if (!ampersand) break;
        cursor = ampersand + 1;
    }
    return callback;
}

static void free_callback(Callback *callback) {
    free(callback->code);
    free(callback->state);
    free(callback->error);
}

static void write_result(const char *path, const Callback *callback) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
    if (fd < 0) die_errno(path);
    const char *name = callback->error ? "error=" : "code=";
    const char *value = callback->error ? callback->error : callback->code;
    write_all(fd, name, strlen(name));
    write_all(fd, value, strlen(value));
    write_all(fd, "\n", 1);
    if (fsync(fd) != 0) die_errno(path);
    if (close(fd) != 0) die_errno(path);
}

static int validate_and_write(const char *pending_path, const char *result_path,
                              const char *callback_text) {
    char *expected_state = read_state(pending_path);
    Callback callback = parse_callback(callback_text);
    if (!callback.state || strcmp(callback.state, expected_state) != 0) {
        free(expected_state);
        free_callback(&callback);
        return 0;
    }
    free(expected_state);
    if ((callback.code != NULL) == (callback.error != NULL)) {
        free_callback(&callback);
        die("OAuth callback must contain exactly one of code or error");
    }
    write_result(result_path, &callback);
    free_callback(&callback);
    return 1;
}

static void write_port_file(const char *path, unsigned port) {
    char text[32];
    int length = snprintf(text, sizeof(text), "%u\n", port);
    if (length < 0 || (size_t)length >= sizeof(text)) die("cannot format loopback port");
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
    if (fd < 0) die_errno(path);
    write_all(fd, text, (size_t)length);
    if (fsync(fd) != 0) die_errno(path);
    if (close(fd) != 0) die_errno(path);
}

static void send_response(int fd, int accepted) {
    const char *body = accepted
        ? "Authorization received. You may close this tab.\n"
        : "Authorization response rejected. Return to the terminal.\n";
    char header[512];
    int length = snprintf(
        header, sizeof(header),
        "HTTP/1.1 %s\r\nContent-Type: text/plain; charset=utf-8\r\n"
        "Content-Length: %zu\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n",
        accepted ? "200 OK" : "400 Bad Request", strlen(body));
    if (length > 0 && (size_t)length < sizeof(header)) {
        (void)send(fd, header, (size_t)length, MSG_NOSIGNAL);
        (void)send(fd, body, strlen(body), MSG_NOSIGNAL);
    }
}

static unsigned parse_timeout(const char *text) {
    char *end = NULL;
    if (!*text) die("OAuth callback timeout must be between 1 and 3600 seconds");
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p)
        if (*p < '0' || *p > '9')
            die("OAuth callback timeout must be between 1 and 3600 seconds");
    errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (errno || !end || *end || value == 0 || value > 3600)
        die("OAuth callback timeout must be between 1 and 3600 seconds");
    return (unsigned)value;
}

static void command_listen(int argc, char **argv) {
    if (argc != 6)
        die("usage: google-oauth-loopback listen PENDING PORT_FILE RESULT_FILE TIMEOUT_SECONDS");

    unsigned timeout = parse_timeout(argv[5]);
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) die_errno("socket");
    int enabled = 1;
    if (setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0)
        die_errno("setsockopt");

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0)
        die_errno("bind loopback OAuth callback");
    if (listen(server, 1) != 0) die_errno("listen");

    socklen_t address_length = sizeof(address);
    if (getsockname(server, (struct sockaddr *)&address, &address_length) != 0)
        die_errno("getsockname");
    write_port_file(argv[3], ntohs(address.sin_port));

    struct pollfd descriptor;
    descriptor.fd = server;
    descriptor.events = POLLIN;
    descriptor.revents = 0;
    int ready;
    do {
        ready = poll(&descriptor, 1, (int)timeout * 1000);
    } while (ready < 0 && errno == EINTR);
    if (ready == 0) die("timed out waiting for OAuth callback");
    if (ready < 0) die_errno("poll");

    int client = accept(server, NULL, NULL);
    if (client < 0) die_errno("accept");
    close(server);

    char request[REQUEST_LIMIT + 1];
    size_t used = 0;
    while (used < REQUEST_LIMIT) {
        ssize_t count = read(client, request + used, REQUEST_LIMIT - used);
        if (count < 0) {
            if (errno == EINTR) continue;
            die_errno("read OAuth callback");
        }
        if (count == 0) break;
        used += (size_t)count;
        if (memchr(request, '\n', used)) break;
    }
    request[used] = '\0';
    char *line_end = strpbrk(request, "\r\n");
    if (line_end) *line_end = '\0';
    if (strncmp(request, "GET ", 4) != 0) {
        send_response(client, 0);
        close(client);
        die("OAuth loopback received a non-GET request");
    }
    char *target = request + 4;
    char *space = strchr(target, ' ');
    if (!space) {
        send_response(client, 0);
        close(client);
        die("OAuth loopback received a malformed request line");
    }
    *space = '\0';
    int accepted = validate_and_write(argv[2], argv[4], target);
    send_response(client, accepted);
    close(client);
    if (!accepted) die("OAuth callback state did not match the pending request");
}

static void command_parse(int argc, char **argv) {
    if (argc != 4)
        die("usage: google-oauth-loopback parse PENDING RESULT_FILE < CALLBACK_URL");
    char input[REQUEST_LIMIT + 1];
    size_t used = fread(input, 1, REQUEST_LIMIT, stdin);
    if (ferror(stdin)) die_errno("read OAuth callback");
    if (!feof(stdin)) die("OAuth callback input is too long");
    input[used] = '\0';
    input[strcspn(input, "\r\n")] = '\0';
    if (!*input) die("OAuth callback input is empty");
    if (!validate_and_write(argv[2], argv[3], input))
        die("OAuth callback state did not match the pending request");
}

int main(int argc, char **argv) {
    umask(077);
    if (argc < 2) die("usage: google-oauth-loopback listen|parse ...");
    if (strcmp(argv[1], "listen") == 0) command_listen(argc, argv);
    else if (strcmp(argv[1], "parse") == 0) command_parse(argc, argv);
    else die("unknown google-oauth-loopback action");
    return 0;
}
