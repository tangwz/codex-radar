#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int valid_name(const char *name) {
  return name[0] != '\0' && strcmp(name, ".") != 0 && strcmp(name, "..") != 0 &&
         strchr(name, '/') == NULL;
}

static int fail(const char *message) {
  fprintf(stderr, "%s: %s\n", message, strerror(errno));
  return 1;
}

int main(int argc, char **argv) {
  struct stat staged_status;
  struct stat destination_status;
  int parent_fd;

  if (argc != 4 || !valid_name(argv[2]) || !valid_name(argv[3])) {
    fprintf(stderr, "usage: atomic_swap PARENT STAGED_NAME DESTINATION_NAME\n");
    return 2;
  }

  parent_fd = open(argv[1], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (parent_fd < 0) {
    return fail("cannot open output parent");
  }
  if (fstatat(parent_fd, argv[2], &staged_status, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISDIR(staged_status.st_mode)) {
    close(parent_fd);
    errno = EINVAL;
    return fail("staged application must be a directory");
  }

  if (fstatat(parent_fd, argv[3], &destination_status, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno != ENOENT) {
      close(parent_fd);
      return fail("cannot inspect destination application");
    }
    if (renameatx_np(parent_fd, argv[2], parent_fd, argv[3], RENAME_EXCL) != 0) {
      close(parent_fd);
      return fail("cannot atomically install application");
    }
  } else {
    if (S_ISLNK(destination_status.st_mode)) {
      close(parent_fd);
      fprintf(stderr, "destination application must not be a symlink\n");
      return 1;
    }
    if (!S_ISDIR(destination_status.st_mode)) {
      close(parent_fd);
      fprintf(stderr, "destination application must be a directory\n");
      return 1;
    }
    if (renameatx_np(parent_fd, argv[2], parent_fd, argv[3], RENAME_SWAP) != 0) {
      close(parent_fd);
      return fail("cannot atomically swap application");
    }
  }

  (void)close(parent_fd);
  return 0;
}
