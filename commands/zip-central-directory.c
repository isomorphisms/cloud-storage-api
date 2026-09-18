/*
 * Classic ZIP central-directory parser for the Grease ranged-Drive path.
 * It never performs network I/O or extraction: Grease supplies bounded byte
 * ranges, and this helper validates/parses only those local slices.
 */
#include <errno.h>
#include <fnmatch.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EOCD_SIG 0x06054b50u
#define CENTRAL_SIG 0x02014b50u

typedef struct {
    char *name;
    size_t name_len;
    uint16_t flags;
    uint16_t method;
    uint32_t crc32;
    uint32_t compressed_size;
    uint32_t uncompressed_size;
    uint32_t local_header_offset;
    uint64_t central_record_offset;
    int directory;
} Entry;

typedef struct {
    const char *kind;
    const char *value;
} Filter;

static void die(const char *message) {
    fprintf(stderr, "%s\n", message);
    exit(2);
}

static uint16_t le16(const unsigned char *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t le32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t parse_u64(const char *text, const char *what) {
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno || !end || *end) {
        fprintf(stderr, "invalid %s: %s\n", what, text);
        exit(2);
    }
    return (uint64_t)value;
}

static unsigned char *read_file(const char *path, size_t *length) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        exit(2);
    }
    if (fseek(f, 0, SEEK_END) != 0) die("cannot seek input");
    long size = ftell(f);
    if (size < 0) die("cannot determine input size");
    if (fseek(f, 0, SEEK_SET) != 0) die("cannot rewind input");
    unsigned char *buffer = malloc((size_t)size + 1);
    if (!buffer) die("out of memory");
    if ((size_t)size && fread(buffer, 1, (size_t)size, f) != (size_t)size)
        die("cannot read input");
    fclose(f);
    *length = (size_t)size;
    return buffer;
}

static int valid_utf8(const unsigned char *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned char c = s[i++];
        if (c < 0x80) continue;
        int need;
        uint32_t code, minimum;
        if ((c & 0xe0) == 0xc0) { need = 1; code = c & 0x1f; minimum = 0x80; }
        else if ((c & 0xf0) == 0xe0) { need = 2; code = c & 0x0f; minimum = 0x800; }
        else if ((c & 0xf8) == 0xf0) { need = 3; code = c & 0x07; minimum = 0x10000; if (code > 4) return 0; }
        else return 0;
        if (i + (size_t)need > n) return 0;
        while (need--) {
            unsigned char d = s[i++];
            if ((d & 0xc0) != 0x80) return 0;
            code = (code << 6) | (d & 0x3f);
        }
        if (code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return 0;
    }
    return 1;
}

static void validate_name(const unsigned char *name, size_t n, uint16_t flags) {
    if (!n) die("ZIP member has an empty name");
    if (name[0] == '/' || name[0] == '\\') die("ZIP member has an absolute path");
    for (size_t i = 0; i < n; ++i)
        if (name[i] == 0) die("ZIP member name contains NUL");
    if (!(flags & 0x0800)) {
        for (size_t i = 0; i < n; ++i)
            if (name[i] >= 0x80) die("ZIP member uses unsupported non-UTF-8 filename encoding");
    } else if (!valid_utf8(name, n)) {
        die("ZIP member has invalid UTF-8 name");
    }
    size_t segment_start = 0;
    for (size_t i = 0; i <= n; ++i) {
        if (i < n && name[i] == '\\') die("ZIP member name contains backslash");
        if (i == n || name[i] == '/') {
            size_t len = i - segment_start;
            if (len == 2 && name[segment_start] == '.' && name[segment_start + 1] == '.')
                die("ZIP member path traversal is not allowed");
            segment_start = i + 1;
        }
    }
    if (n >= 2 && ((name[0] >= 'A' && name[0] <= 'Z') ||
                   (name[0] >= 'a' && name[0] <= 'z')) && name[1] == ':')
        die("ZIP member has a drive-letter path");
}

static int has_zip64_extra(const unsigned char *extra, size_t n) {
    size_t pos = 0;
    while (pos + 4 <= n) {
        uint16_t tag = le16(extra + pos);
        uint16_t size = le16(extra + pos + 2);
        pos += 4;
        if (pos + size > n) die("malformed ZIP extra field");
        if (tag == 0x0001) return 1;
        pos += size;
    }
    if (pos != n) die("malformed ZIP extra field tail");
    return 0;
}

static void json_string(const char *s, size_t n) {
    putchar('"');
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
            case '"': fputs("\\\"", stdout); break;
            case '\\': fputs("\\\\", stdout); break;
            case '\b': fputs("\\b", stdout); break;
            case '\f': fputs("\\f", stdout); break;
            case '\n': fputs("\\n", stdout); break;
            case '\r': fputs("\\r", stdout); break;
            case '\t': fputs("\\t", stdout); break;
            default:
                if (c < 0x20) printf("\\u%04x", c);
                else putchar(c);
        }
    }
    putchar('"');
}

static int entry_name_compare(const void *a, const void *b) {
    const Entry *ea = *(const Entry * const *)a;
    const Entry *eb = *(const Entry * const *)b;
    size_t min = ea->name_len < eb->name_len ? ea->name_len : eb->name_len;
    int cmp = memcmp(ea->name, eb->name, min);
    if (cmp) return cmp;
    if (ea->name_len < eb->name_len) return -1;
    if (ea->name_len > eb->name_len) return 1;
    return 0;
}

static int selected(const Entry *e, const Filter *filters, size_t filter_count) {
    if (!filter_count) return 1;
    for (size_t i = 0; i < filter_count; ++i) {
        if (!strcmp(filters[i].kind, "exact")) {
            size_t n = strlen(filters[i].value);
            if (e->name_len == n && !memcmp(e->name, filters[i].value, n)) return 1;
        } else if (!strcmp(filters[i].kind, "prefix")) {
            size_t n = strlen(filters[i].value);
            if (e->name_len >= n && !memcmp(e->name, filters[i].value, n)) return 1;
        } else if (!strcmp(filters[i].kind, "glob")) {
            if (fnmatch(filters[i].value, e->name, FNM_PATHNAME) == 0) return 1;
        }
    }
    return 0;
}

static void command_tail(int argc, char **argv) {
    if (argc != 3) die("usage: zip-central-directory tail ARCHIVE_SIZE");
    uint64_t archive_size = parse_u64(argv[2], "archive size");
    if (!archive_size) die("ZIP archive is empty");
    const uint64_t window = 65557;
    uint64_t start = archive_size > window ? archive_size - window : 0;
    uint64_t end = archive_size - 1;
    printf("%llu\t%llu\t%llu\n", (unsigned long long)start, (unsigned long long)end, (unsigned long long)(end - start + 1));
}

static void command_eocd(int argc, char **argv) {
    if (argc != 5) die("usage: zip-central-directory eocd ARCHIVE_SIZE TAIL_START TAIL_FILE");
    uint64_t archive_size = parse_u64(argv[2], "archive size");
    uint64_t tail_start = parse_u64(argv[3], "tail start");
    size_t n = 0;
    unsigned char *tail = read_file(argv[4], &n);
    if (tail_start + n != archive_size) die("tail bytes do not reach archive end");
    if (n < 22) die("ZIP tail is too short for end-of-central-directory");

    size_t found = (size_t)-1;
    for (size_t pos = n - 22 + 1; pos-- > 0;) {
        if (le32(tail + pos) != EOCD_SIG) continue;
        uint16_t comment = le16(tail + pos + 20);
        if (pos + 22u + comment == n) { found = pos; break; }
    }
    if (found == (size_t)-1) die("ZIP end-of-central-directory not found in bounded tail");

    uint16_t disk = le16(tail + found + 4);
    uint16_t central_disk = le16(tail + found + 6);
    uint16_t entries_disk = le16(tail + found + 8);
    uint16_t entries_total = le16(tail + found + 10);
    uint32_t central_size = le32(tail + found + 12);
    uint32_t central_offset = le32(tail + found + 16);
    if (disk || central_disk || entries_disk != entries_total)
        die("multi-disk ZIP archives are unsupported");
    if (entries_total == 0xffffu || central_size == 0xffffffffu || central_offset == 0xffffffffu)
        die("ZIP64 archives are unsupported");

    uint64_t eocd_offset = tail_start + found;
    if ((uint64_t)central_offset + central_size > eocd_offset)
        die("central directory overlaps end-of-central-directory");
    uint64_t central_end = central_size ? (uint64_t)central_offset + central_size - 1 : central_offset;
    printf("%u\t%llu\t%u\t%u\t%llu\n", central_offset,
           (unsigned long long)central_end, central_size, entries_total,
           (unsigned long long)eocd_offset);
    free(tail);
}

static void command_list(int argc, char **argv) {
    if (argc < 6) die("usage: zip-central-directory list CENTRAL_OFFSET CENTRAL_SIZE ENTRY_COUNT [FILTERS] CENTRAL_FILE");
    uint64_t central_offset = parse_u64(argv[2], "central offset");
    uint64_t central_size64 = parse_u64(argv[3], "central size");
    uint64_t expected_count64 = parse_u64(argv[4], "entry count");
    if (central_size64 > SIZE_MAX || expected_count64 > SIZE_MAX) die("central directory is too large for this build");
    size_t central_size = (size_t)central_size64;
    size_t expected_count = (size_t)expected_count64;

    Filter *filters = calloc((size_t)argc, sizeof(Filter));
    if (!filters) die("out of memory");
    size_t filter_count = 0;
    int i = 5;
    while (i < argc - 1) {
        if ((!strcmp(argv[i], "--exact") || !strcmp(argv[i], "--prefix") || !strcmp(argv[i], "--glob")) && i + 1 < argc - 1) {
            filters[filter_count].kind = argv[i] + 2;
            filters[filter_count].value = argv[i + 1];
            ++filter_count;
            i += 2;
        } else {
            die("unknown or incomplete ZIP selection option");
        }
    }
    const char *path = argv[argc - 1];
    size_t n = 0;
    unsigned char *data = read_file(path, &n);
    if (n != central_size) die("central-directory range length does not match EOCD");

    Entry *entries = calloc(expected_count ? expected_count : 1, sizeof(Entry));
    if (!entries) die("out of memory");
    size_t count = 0, pos = 0;
    while (pos < n) {
        if (count >= expected_count) die("central directory contains more records than EOCD declares");
        if (n - pos < 46) die("truncated central-directory record");
        const unsigned char *p = data + pos;
        if (le32(p) != CENTRAL_SIG) die("unexpected record in central directory");
        uint16_t flags = le16(p + 8);
        uint16_t method = le16(p + 10);
        uint32_t crc = le32(p + 16);
        uint32_t compressed = le32(p + 20);
        uint32_t uncompressed = le32(p + 24);
        uint16_t name_len = le16(p + 28);
        uint16_t extra_len = le16(p + 30);
        uint16_t comment_len = le16(p + 32);
        uint16_t disk_start = le16(p + 34);
        uint32_t local_offset = le32(p + 42);
        size_t record_len = 46u + name_len + extra_len + comment_len;
        if (record_len > n - pos) die("truncated variable central-directory record");
        const unsigned char *name = p + 46;
        const unsigned char *extra = name + name_len;

        if (flags & 0x0001) die("encrypted ZIP members are unsupported");
        if (method != 0 && method != 8) die("ZIP member compression method is unsupported");
        if (compressed == 0xffffffffu || uncompressed == 0xffffffffu || local_offset == 0xffffffffu || disk_start == 0xffffu || has_zip64_extra(extra, extra_len))
            die("ZIP64 members are unsupported");
        if (disk_start != 0) die("multi-disk ZIP members are unsupported");
        if ((uint64_t)local_offset >= central_offset) die("ZIP member local header does not precede central directory");
        validate_name(name, name_len, flags);

        entries[count].name = malloc((size_t)name_len + 1);
        if (!entries[count].name) die("out of memory");
        memcpy(entries[count].name, name, name_len);
        entries[count].name[name_len] = '\0';
        entries[count].name_len = name_len;
        entries[count].flags = flags;
        entries[count].method = method;
        entries[count].crc32 = crc;
        entries[count].compressed_size = compressed;
        entries[count].uncompressed_size = uncompressed;
        entries[count].local_header_offset = local_offset;
        entries[count].central_record_offset = central_offset + pos;
        entries[count].directory = name_len && name[name_len - 1] == '/';
        ++count;
        pos += record_len;
    }
    if (count != expected_count) die("central directory entry count does not match EOCD");

    Entry **sorted = malloc((count ? count : 1) * sizeof(Entry *));
    if (!sorted) die("out of memory");
    for (size_t j = 0; j < count; ++j) sorted[j] = &entries[j];
    qsort(sorted, count, sizeof(Entry *), entry_name_compare);
    for (size_t j = 1; j < count; ++j)
        if (entry_name_compare(&sorted[j - 1], &sorted[j]) == 0)
            die("duplicate ZIP member names are ambiguous");

    for (size_t j = 0; j < count; ++j) {
        Entry *e = &entries[j];
        if (!selected(e, filters, filter_count)) continue;
        fputs("{\"kind\":\"member\",\"path\":", stdout);
        json_string(e->name, e->name_len);
        printf(",\"compressed_size\":%u,\"uncompressed_size\":%u,\"compression_method\":%u,\"crc32\":\"%08x\",\"general_purpose_flags\":%u,\"local_header_offset\":%u,\"central_directory_record_offset\":%llu,\"directory\":%s}\n",
               e->compressed_size, e->uncompressed_size, e->method, e->crc32,
               e->flags, e->local_header_offset,
               (unsigned long long)e->central_record_offset,
               e->directory ? "true" : "false");
    }

    for (size_t j = 0; j < count; ++j) free(entries[j].name);
    free(sorted); free(entries); free(filters); free(data);
}

int main(int argc, char **argv) {
    if (argc < 2) die("usage: zip-central-directory tail|eocd|list ...");
    if (!strcmp(argv[1], "tail")) command_tail(argc, argv);
    else if (!strcmp(argv[1], "eocd")) command_eocd(argc, argv);
    else if (!strcmp(argv[1], "list")) command_list(argc, argv);
    else die("unknown zip-central-directory action");
    return 0;
}
