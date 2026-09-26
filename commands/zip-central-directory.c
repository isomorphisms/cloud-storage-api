/*
 * ZIP / ZIP64 central-directory parser for the Grease ranged-Drive path.
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
#define ZIP64_EOCD_SIG 0x06064b50u
#define ZIP64_LOCATOR_SIG 0x07064b50u
#define CENTRAL_SIG 0x02014b50u
#define ZIP64_EXTRA 0x0001u
#define MAX_CENTRAL_DIRECTORY_BYTES (64u * 1024u * 1024u)
#define MAX_ENTRY_COUNT 1000000u

typedef struct {
    char *name;
    size_t name_len;
    uint16_t flags;
    uint16_t method;
    uint32_t crc32;
    uint64_t compressed_size;
    uint64_t uncompressed_size;
    uint64_t local_header_offset;
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

static uint64_t le64(const unsigned char *p) {
    return (uint64_t)p[0] | ((uint64_t)p[1] << 8) |
           ((uint64_t)p[2] << 16) | ((uint64_t)p[3] << 24) |
           ((uint64_t)p[4] << 32) | ((uint64_t)p[5] << 40) |
           ((uint64_t)p[6] << 48) | ((uint64_t)p[7] << 56);
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

static void bounded_directory(uint64_t size, uint64_t count) {
    if (size > MAX_CENTRAL_DIRECTORY_BYTES)
        die("ZIP central directory exceeds the 64 MiB inventory bound");
    if (count > MAX_ENTRY_COUNT)
        die("ZIP entry count exceeds the inventory bound");
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

static void resolve_zip64_extra(const unsigned char *extra, size_t n,
                                uint32_t compressed32, uint32_t uncompressed32,
                                uint32_t local_offset32, uint16_t disk_start16,
                                uint64_t *compressed, uint64_t *uncompressed,
                                uint64_t *local_offset, uint32_t *disk_start) {
    int need_uncompressed = uncompressed32 == 0xffffffffu;
    int need_compressed = compressed32 == 0xffffffffu;
    int need_offset = local_offset32 == 0xffffffffu;
    int need_disk = disk_start16 == 0xffffu;
    unsigned required_mask =
        (need_uncompressed ? 1u : 0u) |
        (need_compressed ? 2u : 0u) |
        (need_offset ? 4u : 0u) |
        (need_disk ? 8u : 0u);
    int need_zip64 = required_mask != 0;
    int saw_zip64 = 0;

    *uncompressed = uncompressed32;
    *compressed = compressed32;
    *local_offset = local_offset32;
    *disk_start = disk_start16;

    size_t pos = 0;
    while (pos + 4 <= n) {
        uint16_t tag = le16(extra + pos);
        uint16_t size = le16(extra + pos + 2);
        pos += 4;
        if (pos + size > n) die("malformed ZIP extra field");

        if (tag == ZIP64_EXTRA) {
            if (saw_zip64) die("duplicate ZIP64 extended information extra field");
            saw_zip64 = 1;
            const unsigned char *p = extra + pos;
            int found = 0;
            int ambiguous = 0;
            uint64_t chosen_uncompressed = uncompressed32;
            uint64_t chosen_compressed = compressed32;
            uint64_t chosen_offset = local_offset32;
            uint32_t chosen_disk = disk_start16;

            /*
             * APPNOTE says non-ZIP64 central-directory fields should be omitted
             * from this extra record. Some streaming ZIP writers nevertheless
             * retain redundant values. Accept those only when they exactly
             * agree with the ordinary central-directory fields. Enumerating the
             * possible ordered field subsets keeps required sentinel values
             * unambiguous instead of guessing from record length.
             */
            for (unsigned mask = 0; mask < 16; ++mask) {
                if ((mask & required_mask) != required_mask) continue;

                size_t expected = 0;
                if (mask & 1u) expected += 8;
                if (mask & 2u) expected += 8;
                if (mask & 4u) expected += 8;
                if (mask & 8u) expected += 4;
                if (expected != size) continue;

                size_t z = 0;
                int valid = 1;
                uint64_t candidate_uncompressed = uncompressed32;
                uint64_t candidate_compressed = compressed32;
                uint64_t candidate_offset = local_offset32;
                uint32_t candidate_disk = disk_start16;

                if (mask & 1u) {
                    uint64_t value = le64(p + z); z += 8;
                    if (need_uncompressed) candidate_uncompressed = value;
                    else if (value != uncompressed32) valid = 0;
                }
                if (mask & 2u) {
                    uint64_t value = le64(p + z); z += 8;
                    if (need_compressed) candidate_compressed = value;
                    else if (value != compressed32) valid = 0;
                }
                if (mask & 4u) {
                    uint64_t value = le64(p + z); z += 8;
                    if (need_offset) candidate_offset = value;
                    else if (value != local_offset32) valid = 0;
                }
                if (mask & 8u) {
                    uint32_t value = le32(p + z); z += 4;
                    if (need_disk) candidate_disk = value;
                    else if (value != disk_start16) valid = 0;
                }
                if (!valid || z != size) continue;

                if (!found) {
                    chosen_uncompressed = candidate_uncompressed;
                    chosen_compressed = candidate_compressed;
                    chosen_offset = candidate_offset;
                    chosen_disk = candidate_disk;
                    found = 1;
                } else if (chosen_uncompressed != candidate_uncompressed ||
                           chosen_compressed != candidate_compressed ||
                           chosen_offset != candidate_offset ||
                           chosen_disk != candidate_disk) {
                    ambiguous = 1;
                }
            }

            if (!found)
                die("ZIP64 extended information is inconsistent with central-directory fields");
            if (ambiguous)
                die("ZIP64 extended information is ambiguous");

            *uncompressed = chosen_uncompressed;
            *compressed = chosen_compressed;
            *local_offset = chosen_offset;
            *disk_start = chosen_disk;
        }
        pos += size;
    }
    if (pos != n) die("malformed ZIP extra field tail");
    if (need_zip64 && !saw_zip64)
        die("ZIP64 sentinel field has no ZIP64 extended information");
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

    /* EOCD (22) + max comment (65535) + ZIP64 locator (20). */
    const uint64_t window = 65577;
    uint64_t start = archive_size > window ? archive_size - window : 0;
    uint64_t end = archive_size - 1;
    printf("%llu\t%llu\t%llu\n",
           (unsigned long long)start,
           (unsigned long long)end,
           (unsigned long long)(end - start + 1));
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
    uint64_t eocd_offset = tail_start + found;

    int needs_zip64 = entries_disk == 0xffffu || entries_total == 0xffffu ||
                      central_size == 0xffffffffu || central_offset == 0xffffffffu;

    if (!needs_zip64) {
        if (disk || central_disk || entries_disk != entries_total)
            die("multi-disk ZIP archives are unsupported");
        bounded_directory(central_size, entries_total);
        if ((uint64_t)central_offset + central_size > eocd_offset)
            die("central directory overlaps end-of-central-directory");
        uint64_t central_end = central_size
            ? (uint64_t)central_offset + central_size - 1
            : central_offset;
        printf("classic\t%u\t%llu\t%u\t%u\t%llu\n",
               central_offset,
               (unsigned long long)central_end,
               central_size, entries_total,
               (unsigned long long)eocd_offset);
        free(tail);
        return;
    }

    if (!((disk == 0) || (disk == 0xffffu)) ||
        !((central_disk == 0) || (central_disk == 0xffffu)))
        die("multi-disk ZIP64 archives are unsupported");
    if (found < 20) die("ZIP64 locator is not present in bounded tail");

    const unsigned char *locator = tail + found - 20;
    if (le32(locator) != ZIP64_LOCATOR_SIG)
        die("ZIP64 end-of-central-directory locator is missing");
    uint32_t zip64_disk = le32(locator + 4);
    uint64_t zip64_offset = le64(locator + 8);
    uint32_t total_disks = le32(locator + 16);
    if (zip64_disk != 0 || total_disks != 1)
        die("multi-disk ZIP64 archives are unsupported");

    uint64_t locator_offset = eocd_offset - 20;
    if (zip64_offset >= locator_offset || locator_offset - zip64_offset < 56)
        die("ZIP64 end-of-central-directory offset is invalid");

    printf("zip64\t%llu\t%llu\t56\t%llu\t%llu\n",
           (unsigned long long)zip64_offset,
           (unsigned long long)(zip64_offset + 55),
           (unsigned long long)locator_offset,
           (unsigned long long)eocd_offset);
    free(tail);
}

static void command_zip64_eocd(int argc, char **argv) {
    if (argc != 6)
        die("usage: zip-central-directory zip64-eocd ARCHIVE_SIZE RECORD_START LOCATOR_OFFSET RECORD_FILE");
    uint64_t archive_size = parse_u64(argv[2], "archive size");
    uint64_t record_start = parse_u64(argv[3], "ZIP64 EOCD offset");
    uint64_t locator_offset = parse_u64(argv[4], "ZIP64 locator offset");
    if (locator_offset >= archive_size || record_start >= locator_offset)
        die("ZIP64 end-of-central-directory range is outside archive");

    size_t n = 0;
    unsigned char *record = read_file(argv[5], &n);
    if (n != 56) die("ZIP64 end-of-central-directory fixed range must be 56 bytes");
    if (le32(record) != ZIP64_EOCD_SIG)
        die("ZIP64 end-of-central-directory signature is missing");

    uint64_t remaining_size = le64(record + 4);
    if (remaining_size < 44)
        die("ZIP64 end-of-central-directory record is too short");
    if (remaining_size > UINT64_MAX - 12 ||
        record_start > UINT64_MAX - (remaining_size + 12))
        die("ZIP64 end-of-central-directory size overflows");
    uint64_t record_end_exclusive = record_start + remaining_size + 12;
    if (record_end_exclusive != locator_offset)
        die("ZIP64 end-of-central-directory does not end at its locator");

    uint16_t version_needed = le16(record + 14);
    if (version_needed > 45)
        die("ZIP64 central-directory features newer than version 4.5 are unsupported");

    uint32_t disk = le32(record + 16);
    uint32_t central_disk = le32(record + 20);
    uint64_t entries_disk = le64(record + 24);
    uint64_t entries_total = le64(record + 32);
    uint64_t central_size = le64(record + 40);
    uint64_t central_offset = le64(record + 48);
    if (disk != 0 || central_disk != 0 || entries_disk != entries_total)
        die("multi-disk ZIP64 archives are unsupported");

    bounded_directory(central_size, entries_total);
    if (central_offset > record_start ||
        central_size > record_start - central_offset)
        die("ZIP64 central directory overlaps ZIP64 end-of-central-directory");
    uint64_t central_end = central_size
        ? central_offset + central_size - 1
        : central_offset;

    printf("%llu\t%llu\t%llu\t%llu\t%llu\n",
           (unsigned long long)central_offset,
           (unsigned long long)central_end,
           (unsigned long long)central_size,
           (unsigned long long)entries_total,
           (unsigned long long)record_start);
    free(record);
}

static void command_list(int argc, char **argv) {
    if (argc < 6)
        die("usage: zip-central-directory list CENTRAL_OFFSET CENTRAL_SIZE ENTRY_COUNT [FILTERS] CENTRAL_FILE");
    uint64_t central_offset = parse_u64(argv[2], "central offset");
    uint64_t central_size64 = parse_u64(argv[3], "central size");
    uint64_t expected_count64 = parse_u64(argv[4], "entry count");
    bounded_directory(central_size64, expected_count64);
    if (central_size64 > SIZE_MAX || expected_count64 > SIZE_MAX)
        die("central directory is too large for this build");
    size_t central_size = (size_t)central_size64;
    size_t expected_count = (size_t)expected_count64;

    Filter *filters = calloc((size_t)argc, sizeof(Filter));
    if (!filters) die("out of memory");
    size_t filter_count = 0;
    int i = 5;
    while (i < argc - 1) {
        if ((!strcmp(argv[i], "--exact") ||
             !strcmp(argv[i], "--prefix") ||
             !strcmp(argv[i], "--glob")) && i + 1 < argc - 1) {
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
        if (count >= expected_count)
            die("central directory contains more records than EOCD declares");
        if (n - pos < 46) die("truncated central-directory record");
        const unsigned char *p = data + pos;
        if (le32(p) != CENTRAL_SIG) die("unexpected record in central directory");

        uint16_t version_needed = le16(p + 6);
        uint16_t flags = le16(p + 8);
        uint16_t method = le16(p + 10);
        uint32_t crc = le32(p + 16);
        uint32_t compressed32 = le32(p + 20);
        uint32_t uncompressed32 = le32(p + 24);
        uint16_t name_len = le16(p + 28);
        uint16_t extra_len = le16(p + 30);
        uint16_t comment_len = le16(p + 32);
        uint16_t disk_start16 = le16(p + 34);
        uint32_t local_offset32 = le32(p + 42);
        size_t record_len = 46u + name_len + extra_len + comment_len;
        if (record_len > n - pos) die("truncated variable central-directory record");

        const unsigned char *name = p + 46;
        const unsigned char *extra = name + name_len;

        if (version_needed > 45)
            die("ZIP member requires extraction features newer than version 4.5");
        if (flags & 0x0001) die("encrypted ZIP members are unsupported");
        if (method != 0 && method != 8)
            die("ZIP member compression method is unsupported");

        uint64_t compressed, uncompressed, local_offset;
        uint32_t disk_start;
        resolve_zip64_extra(extra, extra_len,
                            compressed32, uncompressed32,
                            local_offset32, disk_start16,
                            &compressed, &uncompressed,
                            &local_offset, &disk_start);
        if (disk_start != 0) die("multi-disk ZIP members are unsupported");
        if (local_offset >= central_offset)
            die("ZIP member local header does not precede central directory");
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
    if (count != expected_count)
        die("central directory entry count does not match EOCD");

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
        printf(",\"compressed_size\":%llu,\"uncompressed_size\":%llu,"
               "\"compression_method\":%u,\"crc32\":\"%08x\","
               "\"general_purpose_flags\":%u,\"local_header_offset\":%llu,"
               "\"central_directory_record_offset\":%llu,\"directory\":%s}\n",
               (unsigned long long)e->compressed_size,
               (unsigned long long)e->uncompressed_size,
               e->method, e->crc32, e->flags,
               (unsigned long long)e->local_header_offset,
               (unsigned long long)e->central_record_offset,
               e->directory ? "true" : "false");
    }

    for (size_t j = 0; j < count; ++j) free(entries[j].name);
    free(sorted);
    free(entries);
    free(filters);
    free(data);
}

int main(int argc, char **argv) {
    if (argc < 2) die("usage: zip-central-directory tail|eocd|zip64-eocd|list ...");
    if (!strcmp(argv[1], "tail")) command_tail(argc, argv);
    else if (!strcmp(argv[1], "eocd")) command_eocd(argc, argv);
    else if (!strcmp(argv[1], "zip64-eocd")) command_zip64_eocd(argc, argv);
    else if (!strcmp(argv[1], "list")) command_list(argc, argv);
    else die("unknown zip-central-directory action");
    return 0;
}
