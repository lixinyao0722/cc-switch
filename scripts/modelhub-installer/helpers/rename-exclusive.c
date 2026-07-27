#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>

enum {
  EXIT_RENAME_FAILURE = 1,
  EXIT_DESTINATION_EXISTS = 17,
  EXIT_IDENTITY_MISMATCH = 18,
  EXIT_USAGE = 64,
};

static int parse_identity(const char *value, unsigned long long *result) {
  char *end = NULL;
  unsigned long long parsed;

  errno = 0;
  parsed = strtoull(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0') {
    return -1;
  }
  *result = parsed;
  return 0;
}

int main(int argc, char *argv[]) {
  struct stat source_stat;
  unsigned long long expected_device;
  unsigned long long expected_inode;

  if (argc != 5) {
    fprintf(stderr, "usage: rename-exclusive SOURCE TARGET DEVICE INODE\n");
    return EXIT_USAGE;
  }
  if (parse_identity(argv[3], &expected_device) != 0 ||
      parse_identity(argv[4], &expected_inode) != 0) {
    fprintf(stderr, "invalid source identity\n");
    return EXIT_USAGE;
  }
  if (lstat(argv[1], &source_stat) != 0) {
    fprintf(stderr, "unable to inspect source: %s\n", strerror(errno));
    return EXIT_RENAME_FAILURE;
  }
  if (S_ISLNK(source_stat.st_mode) ||
      (unsigned long long)source_stat.st_dev != expected_device ||
      (unsigned long long)source_stat.st_ino != expected_inode) {
    fprintf(stderr, "source identity changed\n");
    return EXIT_IDENTITY_MISMATCH;
  }

  if (renamex_np(argv[1], argv[2], RENAME_EXCL) == 0) {
    return 0;
  }
  if (errno == EEXIST) {
    fprintf(stderr, "destination already exists\n");
    return EXIT_DESTINATION_EXISTS;
  }

  fprintf(stderr, "renamex_np failed: %s\n", strerror(errno));
  return EXIT_RENAME_FAILURE;
}
