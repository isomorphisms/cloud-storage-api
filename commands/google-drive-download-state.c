/*
 * Fixed-width transfer arithmetic and durable file transitions for the Drive
 * downloader.  Grease owns provider semantics and HTTP; this helper keeps
 * offsets above 4 GiB and append/fsync boundaries out of shell arithmetic.
 */
#define _FILE_OFFSET_BITS 64
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static void die(const char *message) {
    fprintf(stderr, "%s\n", message);
    exit(2);
}

static void die_errno(const char *path) {
    perror(path);
    exit(2);
}

static uint64_t parse_u64(const char *text, const char *name) {
    char *end = NULL;
    if (!*text) {
        fprintf(stderr, "invalid %s: %s\n", name, text);
        exit(2);
    }
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        if (*p < '0' || *p > '9') {
            fprintf(stderr, "invalid %s: %s\n", name, text);
            exit(2);
        }
    }
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno || !end || *end) {
        fprintf(stderr, "invalid %s: %s\n", name, text);
        exit(2);
    }
    return (uint64_t)value;
}

static uint64_t file_size(const char *path) {
    struct stat status;
    if (stat(path, &status) != 0) die_errno(path);
    if (status.st_size < 0) die("file has a negative size");
    return (uint64_t)status.st_size;
}

static void fsync_parent(const char *path) {
    char *copy = strdup(path);
    if (!copy) die("out of memory");
    char *slash = strrchr(copy, '/');
    const char *directory = ".";
    if (slash) {
        if (slash == copy) slash[1] = '\0';
        else *slash = '\0';
        directory = copy;
    }
    int fd = open(directory, O_RDONLY | O_DIRECTORY);
    if (fd >= 0) {
        if (fsync(fd) != 0 && errno != EINVAL && errno != ENOTSUP && errno != EROFS)
            die_errno(directory);
        if (close(fd) != 0) die_errno(directory);
    } else if (errno != EACCES && errno != EINVAL && errno != ENOTSUP) {
        die_errno(directory);
    }
    free(copy);
}

static void command_size(int argc, char **argv) {
    if (argc != 3) die("usage: google-drive-download-state size FILE");
    printf("%llu\n", (unsigned long long)file_size(argv[2]));
}

static void command_plan(int argc, char **argv) {
    if (argc != 5)
        die("usage: google-drive-download-state plan TOTAL COMPLETE CHUNK_SIZE");
    uint64_t total = parse_u64(argv[2], "total size");
    uint64_t complete = parse_u64(argv[3], "complete byte count");
    uint64_t chunk = parse_u64(argv[4], "chunk size");
    if (!chunk) die("chunk size must be positive");
    if (complete > total) die("complete byte count exceeds expected size");
    if (complete == total) {
        printf("complete\n");
        return;
    }
    uint64_t remaining = total - complete;
    uint64_t length = remaining < chunk ? remaining : chunk;
    uint64_t end = complete + length - 1;
    printf("range\t%llu\t%llu\t%llu\t%llu\n",
           (unsigned long long)complete,
           (unsigned long long)end,
           (unsigned long long)length,
           (unsigned long long)(end + 1));
}

static void command_reconcile(int argc, char **argv) {
    if (argc != 5)
        die("usage: google-drive-download-state reconcile PARTIAL RECORDED EXPECTED");
    uint64_t recorded = parse_u64(argv[3], "recorded size");
    uint64_t expected = parse_u64(argv[4], "expected size");
    uint64_t actual = file_size(argv[2]);
    if (recorded > expected) die("recorded byte count exceeds expected size");
    if (actual < recorded) {
        printf("short\t%llu\t%llu\n",
               (unsigned long long)actual, (unsigned long long)recorded);
    } else if (actual > recorded) {
        printf("truncate\t%llu\t%llu\n",
               (unsigned long long)actual, (unsigned long long)recorded);
    } else {
        printf("exact\t%llu\t%llu\n",
               (unsigned long long)actual, (unsigned long long)recorded);
    }
}

static void command_append(int argc, char **argv) {
    if (argc != 6)
        die("usage: google-drive-download-state append PARTIAL SEGMENT EXPECTED_START EXPECTED_LENGTH");
    const char *partial_path = argv[2];
    const char *segment_path = argv[3];
    uint64_t expected_start = parse_u64(argv[4], "expected start");
    uint64_t expected_length = parse_u64(argv[5], "expected length");
    if (file_size(partial_path) != expected_start)
        die("partial file length does not match the next segment offset");
    if (file_size(segment_path) != expected_length)
        die("segment file length does not match the requested range");
    if (expected_length > UINT64_MAX - expected_start)
        die("segment end offset overflows 64 bits");

    int input = open(segment_path, O_RDONLY);
    if (input < 0) die_errno(segment_path);
    int output = open(partial_path, O_WRONLY | O_APPEND);
    if (output < 0) die_errno(partial_path);

    char buffer[65536];
    uint64_t copied = 0;
    while (copied < expected_length) {
        size_t wanted = sizeof(buffer);
        if (expected_length - copied < wanted)
            wanted = (size_t)(expected_length - copied);
        ssize_t count = read(input, buffer, wanted);
        if (count < 0) {
            if (errno == EINTR) continue;
            die_errno(segment_path);
        }
        if (count == 0) die("segment ended before its expected length");
        size_t offset = 0;
        while (offset < (size_t)count) {
            ssize_t written = write(output, buffer + offset, (size_t)count - offset);
            if (written < 0) {
                if (errno == EINTR) continue;
                die_errno(partial_path);
            }
            offset += (size_t)written;
        }
        copied += (uint64_t)count;
    }
    if (close(input) != 0) die_errno(segment_path);
    if (fsync(output) != 0) die_errno(partial_path);
    if (close(output) != 0) die_errno(partial_path);
    if (file_size(partial_path) != expected_start + expected_length)
        die("partial file length is wrong after appending a segment");
}

static void command_truncate(int argc, char **argv) {
    if (argc != 4) die("usage: google-drive-download-state truncate FILE SIZE");
    uint64_t size = parse_u64(argv[3], "truncate size");
    if (size > (uint64_t)INT64_MAX) die("truncate size exceeds signed 64-bit file offsets");
    int fd = open(argv[2], O_WRONLY);
    if (fd < 0) die_errno(argv[2]);
    if (ftruncate(fd, (off_t)size) != 0) die_errno(argv[2]);
    if (fsync(fd) != 0) die_errno(argv[2]);
    if (close(fd) != 0) die_errno(argv[2]);
}

static void durable_rename(const char *source, const char *destination) {
    int fd = open(source, O_RDONLY);
    if (fd < 0) die_errno(source);
    if (fsync(fd) != 0) die_errno(source);
    if (close(fd) != 0) die_errno(source);
    if (rename(source, destination) != 0) die_errno(destination);
    fsync_parent(destination);
}

static void command_commit(int argc, char **argv) {
    if (argc != 4) die("usage: google-drive-download-state commit TEMP FINAL");
    durable_rename(argv[2], argv[3]);
}

static void command_finalize(int argc, char **argv) {
    if (argc != 5)
        die("usage: google-drive-download-state finalize PARTIAL DESTINATION EXPECTED_SIZE");
    uint64_t expected = parse_u64(argv[4], "expected size");
    if (file_size(argv[2]) != expected)
        die("partial file length does not match expected final size");
    struct stat destination;
    if (lstat(argv[3], &destination) == 0)
        die("destination already exists");
    if (errno != ENOENT) die_errno(argv[3]);
    durable_rename(argv[2], argv[3]);
}

int main(int argc, char **argv) {
    if (argc < 2) die("usage: google-drive-download-state size|plan|reconcile|append|truncate|commit|finalize ...");
    if (strcmp(argv[1], "size") == 0) command_size(argc, argv);
    else if (strcmp(argv[1], "plan") == 0) command_plan(argc, argv);
    else if (strcmp(argv[1], "reconcile") == 0) command_reconcile(argc, argv);
    else if (strcmp(argv[1], "append") == 0) command_append(argc, argv);
    else if (strcmp(argv[1], "truncate") == 0) command_truncate(argc, argv);
    else if (strcmp(argv[1], "commit") == 0) command_commit(argc, argv);
    else if (strcmp(argv[1], "finalize") == 0) command_finalize(argc, argv);
    else die("unknown google-drive-download-state action");
    return 0;
}
