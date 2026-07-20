#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static const unsigned int kRenameSafetyFlags =
    RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH;

static int valid_name(const char *name) {
  return name[0] != '\0' && strcmp(name, ".") != 0 && strcmp(name, "..") != 0 &&
         strchr(name, '/') == NULL;
}

static int fail(const char *message) {
  fprintf(stderr, "%s: %s\n", message, strerror(errno));
  return 1;
}

static int parse_identity(const char *value, uint64_t *result) {
  char *end = NULL;
  unsigned long long parsed;

  errno = 0;
  parsed = strtoull(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0') {
    return -1;
  }
  *result = (uint64_t)parsed;
  return 0;
}

static int same_identity(const struct stat *status, uint64_t device, uint64_t inode) {
  return (uint64_t)status->st_dev == device && (uint64_t)status->st_ino == inode;
}

static int trusted_directory(const struct stat *status) {
  return S_ISDIR(status->st_mode) && status->st_uid == geteuid() &&
         (status->st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static int open_verified_parent(const char *path, uint64_t device, uint64_t inode) {
  struct stat status;
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY);

  if (fd < 0) {
    return -1;
  }
  if (fstat(fd, &status) != 0 || !same_identity(&status, device, inode) ||
      !trusted_directory(&status)) {
    close(fd);
    errno = ESTALE;
    return -1;
  }
  return fd;
}

static int verify_named_directory(int parent_fd, const char *name, uint64_t device,
                                  uint64_t inode, struct stat *status_out) {
  struct stat status;
  int fd = openat(parent_fd, name,
                  O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY);

  if (fd < 0) {
    return -1;
  }
  if (fstat(fd, &status) != 0 || !same_identity(&status, device, inode)) {
    close(fd);
    errno = ESTALE;
    return -1;
  }
  if (status_out != NULL) {
    *status_out = status;
  }
  return fd;
}

static int pause_before_rename(void) {
  const char *ready_path = getenv("PACKAGE_APP_TEST_HELPER_PAUSE_READY");
  const char *continue_path = getenv("PACKAGE_APP_TEST_HELPER_PAUSE_CONTINUE");
  struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000};
  int ready_fd;
  int attempts;

  if (ready_path == NULL && continue_path == NULL) {
    return 0;
  }
  if (ready_path == NULL || continue_path == NULL) {
    errno = EINVAL;
    return -1;
  }
  ready_fd = open(ready_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  if (ready_fd < 0) {
    return -1;
  }
  close(ready_fd);
  for (attempts = 0; attempts < 1000; attempts++) {
    if (access(continue_path, F_OK) == 0) {
      return 0;
    }
    nanosleep(&delay, NULL);
  }
  errno = ETIMEDOUT;
  return -1;
}

static int remove_tree_contents(int directory_fd) {
  struct dirent *entry;
  DIR *directory = fdopendir(dup(directory_fd));

  if (directory == NULL) {
    return -1;
  }
  while ((entry = readdir(directory)) != NULL) {
    struct stat before;
    struct stat after;
    int child_fd;

    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    if (fstatat(directory_fd, entry->d_name, &before, AT_SYMLINK_NOFOLLOW) != 0) {
      closedir(directory);
      return -1;
    }
    if (S_ISDIR(before.st_mode)) {
      child_fd = openat(directory_fd, entry->d_name,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY);
      if (child_fd < 0 || remove_tree_contents(child_fd) != 0 ||
          fstatat(directory_fd, entry->d_name, &after, AT_SYMLINK_NOFOLLOW) != 0 ||
          before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
          unlinkat(directory_fd, entry->d_name, AT_REMOVEDIR) != 0) {
        if (child_fd >= 0) {
          close(child_fd);
        }
        closedir(directory);
        return -1;
      }
      close(child_fd);
    } else if (unlinkat(directory_fd, entry->d_name, 0) != 0) {
      closedir(directory);
      return -1;
    }
  }
  return closedir(directory);
}

static int remove_verified(int parent_fd, const char *name, uint64_t device,
                           uint64_t inode) {
  struct stat after;
  int directory_fd = verify_named_directory(parent_fd, name, device, inode, NULL);

  if (directory_fd < 0) {
    return -1;
  }
  if (remove_tree_contents(directory_fd) != 0 ||
      fstatat(parent_fd, name, &after, AT_SYMLINK_NOFOLLOW) != 0 ||
      !same_identity(&after, device, inode) ||
      unlinkat(parent_fd, name, AT_REMOVEDIR) != 0) {
    close(directory_fd);
    return -1;
  }
  return close(directory_fd);
}

static int lock_parent(int argc, char **argv) {
  struct proc_bsdinfo process_info;
  struct stat lock_status;
  struct stat named_status;
  uint64_t parent_device;
  uint64_t parent_inode;
  int parent_fd;
  int lock_fd;

  if (argc != 6 || !valid_name(argv[3]) ||
      parse_identity(argv[4], &parent_device) != 0 ||
      parse_identity(argv[5], &parent_inode) != 0) {
    fprintf(stderr, "usage: atomic_swap lock PARENT LOCK_NAME PARENT_DEV PARENT_INO\n");
    return 2;
  }
  parent_fd = open_verified_parent(argv[2], parent_device, parent_inode);
  if (parent_fd < 0) {
    return fail("output parent identity changed");
  }
  lock_fd = openat(parent_fd, argv[3],
                   O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW_ANY, 0600);
  if (lock_fd < 0 || fstat(lock_fd, &lock_status) != 0 ||
      !S_ISREG(lock_status.st_mode) || lock_status.st_uid != geteuid() ||
      lock_status.st_nlink != 1) {
    close(parent_fd);
    if (lock_fd >= 0) {
      close(lock_fd);
    }
    errno = EINVAL;
    return fail("invalid package lock file");
  }
  if (flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
    close(lock_fd);
    close(parent_fd);
    fprintf(stderr, "output path is locked by another packager\n");
    return 1;
  }
  if (fstatat(parent_fd, argv[3], &named_status, AT_SYMLINK_NOFOLLOW) != 0 ||
      named_status.st_dev != lock_status.st_dev ||
      named_status.st_ino != lock_status.st_ino) {
    close(lock_fd);
    close(parent_fd);
    errno = ESTALE;
    return fail("package lock identity changed");
  }
  if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &process_info,
                   sizeof(process_info)) != sizeof(process_info) ||
      ftruncate(lock_fd, 0) != 0 ||
      dprintf(lock_fd, "pid=%d\nstart=%llu.%llu\n", getpid(),
              process_info.pbi_start_tvsec, process_info.pbi_start_tvusec) < 0 ||
      fsync(lock_fd) != 0) {
    close(lock_fd);
    close(parent_fd);
    return fail("cannot write package lock owner record");
  }
  printf("LOCKED\n");
  fflush(stdout);
  while (read(STDIN_FILENO, &lock_status, sizeof(lock_status)) > 0) {
  }
  close(lock_fd);
  close(parent_fd);
  return 0;
}

static int swap_application(int argc, char **argv) {
  struct stat staged_status;
  struct stat destination_status;
  struct stat after_status;
  uint64_t parent_device;
  uint64_t parent_inode;
  uint64_t staged_device;
  uint64_t staged_inode;
  int destination_fd = -1;
  int staged_fd;
  int parent_fd;
  int recheck_fd;
  int destination_exists = 1;
  unsigned int rename_flags;

  if (argc != 9 || !valid_name(argv[3]) || !valid_name(argv[4]) ||
      parse_identity(argv[5], &parent_device) != 0 ||
      parse_identity(argv[6], &parent_inode) != 0 ||
      parse_identity(argv[7], &staged_device) != 0 ||
      parse_identity(argv[8], &staged_inode) != 0) {
    fprintf(stderr, "usage: atomic_swap swap PARENT STAGED DEST PARENT_DEV PARENT_INO STAGED_DEV STAGED_INO\n");
    return 2;
  }
  parent_fd = open_verified_parent(argv[2], parent_device, parent_inode);
  if (parent_fd < 0) {
    return fail("output parent identity changed");
  }
  staged_fd = verify_named_directory(parent_fd, argv[3], staged_device,
                                      staged_inode, &staged_status);
  if (staged_fd < 0) {
    close(parent_fd);
    return fail("staged application identity changed");
  }
  destination_fd = openat(parent_fd, argv[4],
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY);
  if (destination_fd < 0) {
    if (errno != ENOENT) {
      close(staged_fd);
      close(parent_fd);
      fprintf(stderr, "destination application must be a real directory\n");
      return 1;
    }
    destination_exists = 0;
  } else if (fstat(destination_fd, &destination_status) != 0) {
    close(destination_fd);
    close(staged_fd);
    close(parent_fd);
    return fail("cannot inspect destination application");
  }
  if (pause_before_rename() != 0) {
    close(destination_fd);
    close(staged_fd);
    close(parent_fd);
    return fail("helper pause failed");
  }
  recheck_fd = open_verified_parent(argv[2], parent_device, parent_inode);
  if (recheck_fd < 0) {
    close(destination_fd);
    close(staged_fd);
    close(parent_fd);
    return fail("output parent identity changed before commit");
  }
  close(recheck_fd);
  recheck_fd = verify_named_directory(parent_fd, argv[3], staged_device,
                                      staged_inode, NULL);
  if (recheck_fd < 0) {
    close(destination_fd);
    close(staged_fd);
    close(parent_fd);
    return fail("staged application identity changed before commit");
  }
  close(recheck_fd);
  if (destination_exists) {
    recheck_fd = verify_named_directory(parent_fd, argv[4],
                                        (uint64_t)destination_status.st_dev,
                                        (uint64_t)destination_status.st_ino, NULL);
    if (recheck_fd < 0) {
      close(destination_fd);
      close(staged_fd);
      close(parent_fd);
      return fail("destination application identity changed before commit");
    }
    close(recheck_fd);
  } else if (fstatat(parent_fd, argv[4], &after_status, AT_SYMLINK_NOFOLLOW) == 0 ||
             errno != ENOENT) {
    close(staged_fd);
    close(parent_fd);
    errno = ESTALE;
    return fail("destination application appeared before commit");
  }

  rename_flags = kRenameSafetyFlags |
                 (destination_exists ? RENAME_SWAP : RENAME_EXCL);
  if (renameatx_np(parent_fd, argv[3], parent_fd, argv[4], rename_flags) != 0) {
    close(destination_fd);
    close(staged_fd);
    close(parent_fd);
    return fail("cannot atomically commit application");
  }
  if (fstatat(parent_fd, argv[4], &after_status, AT_SYMLINK_NOFOLLOW) != 0 ||
      !same_identity(&after_status, staged_device, staged_inode)) {
    if (destination_exists) {
      (void)renameatx_np(parent_fd, argv[3], parent_fd, argv[4], rename_flags);
    } else {
      (void)renameatx_np(parent_fd, argv[4], parent_fd, argv[3],
                         kRenameSafetyFlags | RENAME_EXCL);
    }
    close(destination_fd);
    close(staged_fd);
    close(parent_fd);
    errno = ESTALE;
    return fail("committed application identity mismatch");
  }
  if (destination_exists) {
    if (fstatat(parent_fd, argv[3], &after_status, AT_SYMLINK_NOFOLLOW) != 0 ||
        after_status.st_dev != destination_status.st_dev ||
        after_status.st_ino != destination_status.st_ino) {
      (void)renameatx_np(parent_fd, argv[3], parent_fd, argv[4], rename_flags);
      close(destination_fd);
      close(staged_fd);
      close(parent_fd);
      errno = ESTALE;
      return fail("old application identity mismatch after commit");
    }
    if (getenv("PACKAGE_APP_TEST_CLEANUP_FAILURE") != NULL ||
        remove_verified(parent_fd, argv[3],
                        (uint64_t)destination_status.st_dev,
                        (uint64_t)destination_status.st_ino) != 0) {
      fprintf(stderr, "warning: retained verified old application at %s\n", argv[3]);
    }
  }
  close(destination_fd);
  close(staged_fd);
  close(parent_fd);
  return 0;
}

static int remove_application(int argc, char **argv) {
  uint64_t parent_device;
  uint64_t parent_inode;
  uint64_t entry_device;
  uint64_t entry_inode;
  int parent_fd;
  int result;

  if (argc != 8 || !valid_name(argv[3]) ||
      parse_identity(argv[4], &parent_device) != 0 ||
      parse_identity(argv[5], &parent_inode) != 0 ||
      parse_identity(argv[6], &entry_device) != 0 ||
      parse_identity(argv[7], &entry_inode) != 0) {
    fprintf(stderr, "usage: atomic_swap remove PARENT NAME PARENT_DEV PARENT_INO ENTRY_DEV ENTRY_INO\n");
    return 2;
  }
  parent_fd = open_verified_parent(argv[2], parent_device, parent_inode);
  if (parent_fd < 0) {
    return fail("output parent identity changed");
  }
  result = remove_verified(parent_fd, argv[3], entry_device, entry_inode);
  close(parent_fd);
  return result == 0 ? 0 : fail("refused to remove changed staging application");
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: atomic_swap lock|swap|remove ...\n");
    return 2;
  }
  if (strcmp(argv[1], "lock") == 0) {
    return lock_parent(argc, argv);
  }
  if (strcmp(argv[1], "swap") == 0) {
    return swap_application(argc, argv);
  }
  if (strcmp(argv[1], "remove") == 0) {
    return remove_application(argc, argv);
  }
  fprintf(stderr, "unknown atomic_swap command\n");
  return 2;
}
