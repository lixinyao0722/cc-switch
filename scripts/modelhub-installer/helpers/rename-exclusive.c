#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/attr.h>

enum {
  EXIT_RENAME_FAILURE = 1,
  EXIT_DESTINATION_EXISTS = 17,
  EXIT_USAGE = 64,
};

int main(int argc, char *argv[]) {
  if (argc != 3) {
    fprintf(stderr, "usage: rename-exclusive SOURCE TARGET\n");
    return EXIT_USAGE;
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
