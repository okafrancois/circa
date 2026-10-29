// Descriptor-anchored filesystem operations of the Orbit Chromium bridge (CHROMIUM-APP-R3, review
// HIGH 2 / MEDIUM 5 / MEDIUM 6). POSIX only, no CEF: unit-tested with real descriptors
// (native/OrbitChromium/Tests/BridgePolicyTests.cc).
// The engine root (CEF root_cache_path) is opened once at start-up with its identity recorded.
// Every later operation on a profile directory goes through that descriptor (fstatat, renameat,
// openat, unlinkat), never through a path recomputed from the root's name: replacing the root or
// one of its ancestors by a symbolic link afterwards can neither redirect a deletion nor make a
// foreign directory look like a profile.

#ifndef ORBIT_BRIDGE_FILES_H
#define ORBIT_BRIDGE_FILES_H

#include <dirent.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <optional>
#include <string>
#include <utility>

namespace orbit_bridge {

struct FileIdentity {
  dev_t device = 0;
  ino_t inode = 0;
  bool operator==(const FileIdentity& other) const { return device == other.device && inode == other.inode; }
};

inline std::optional<FileIdentity> IdentityOfPath(const std::string& path) {
  struct stat info {};
  if (stat(path.c_str(), &info) != 0) return std::nullopt;
  return FileIdentity{info.st_dev, info.st_ino};
}

// A direct child name: no separator, not "." or "..", not empty.
inline bool IsValidChildName(const std::string& name) {
  return !name.empty() && name.size() <= 255 && name != "." && name != ".." && name.find('/') == std::string::npos
         && name.find('\0') == std::string::npos;
}

class AnchoredRoot {
 public:
  enum class Entry { kAbsent, kDirectory, kOther, kError };
  enum class Removal {
    kRemoved,  // Something existed and was removed.
    kAbsent,   // Nothing to remove.
    kRefused,  // The root's name no longer designates the anchored directory, or invalid name.
    kFailed,   // Removal started and left something behind.
  };

  // Refuses a root that is not a directory or is reached through a symbolic link anywhere in its
  // path (its realpath must be the path itself).
  static std::unique_ptr<AnchoredRoot> Open(const std::string& path) {
    char resolved[PATH_MAX];
    if (path.empty() || path[0] != '/' || !realpath(path.c_str(), resolved) || path != resolved) return nullptr;
    const int fd = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nullptr;
    struct stat info {};
    if (fstat(fd, &info) != 0 || !S_ISDIR(info.st_mode)) {
      close(fd);
      return nullptr;
    }
    return std::unique_ptr<AnchoredRoot>(new AnchoredRoot(path, fd, FileIdentity{info.st_dev, info.st_ino}));
  }

  ~AnchoredRoot() { close(fd_); }
  AnchoredRoot(const AnchoredRoot&) = delete;
  AnchoredRoot& operator=(const AnchoredRoot&) = delete;

  int fd() const { return fd_; }
  const std::string& path() const { return path_; }
  FileIdentity identity() const { return identity_; }

  // The root's name still designates the anchored directory, without any symbolic link.
  bool StillAtPath() const {
    char resolved[PATH_MAX];
    if (!realpath(path_.c_str(), resolved) || path_ != resolved) return false;
    const auto current = IdentityOfPath(path_);
    return current && *current == identity_;
  }

  Entry Inspect(const std::string& name) const {
    if (!IsValidChildName(name)) return Entry::kError;
    struct stat info {};
    if (fstatat(fd_, name.c_str(), &info, AT_SYMLINK_NOFOLLOW) != 0) return errno == ENOENT ? Entry::kAbsent : Entry::kError;
    return S_ISDIR(info.st_mode) ? Entry::kDirectory : Entry::kOther;
  }

  std::optional<FileIdentity> IdentityOf(const std::string& name) const {
    struct stat info {};
    if (!IsValidChildName(name) || fstatat(fd_, name.c_str(), &info, AT_SYMLINK_NOFOLLOW) != 0) return std::nullopt;
    return FileIdentity{info.st_dev, info.st_ino};
  }

  // A retired tree owns a duplicate root descriptor, so cleanup survives bridge teardown.
  class RetiredChild {
   public:
    RetiredChild(int fd, std::string name) : fd_(fd), name_(std::move(name)) {}
    ~RetiredChild() { close(fd_); }
    bool Remove() const { return RemoveTree(fd_, name_.c_str()); }
   private:
    int fd_;
    std::string name_;
  };

  // Authority checks and atomic retirement stay on the UI thread. Recursive IO uses only the
  // returned descriptor and tombstone, with no access to Chrome or bridge global state.
  Removal RetireChild(const std::string& name, std::unique_ptr<RetiredChild>* retired) const {
    if (!retired || !IsValidChildName(name) || !StillAtPath()) return Removal::kRefused;
    retired->reset();
    switch (Inspect(name)) {
      case Entry::kAbsent: return Removal::kAbsent;
      case Entry::kError: return Removal::kFailed;
      case Entry::kOther: return unlinkat(fd_, name.c_str(), 0) == 0 ? Removal::kRemoved : Removal::kFailed;
      case Entry::kDirectory: break;
    }
    const int worker_fd = fcntl(fd_, F_DUPFD_CLOEXEC, 0);
    if (worker_fd < 0) return Removal::kFailed;
    char tombstone[64];
    snprintf(tombstone, sizeof(tombstone), ".orbit-removed-%08x%08x", arc4random(), arc4random());
    if (renameat(fd_, name.c_str(), fd_, tombstone) != 0) { close(worker_fd); return Removal::kFailed; }
    *retired = std::make_unique<RetiredChild>(worker_fd, tombstone);
    return Removal::kRemoved;
  }

  Removal RemoveChild(const std::string& name) const {
    std::unique_ptr<RetiredChild> retired;
    const auto result = RetireChild(name, &retired);
    if (retired && !retired->Remove()) return Removal::kFailed;
    return result;
  }

 private:
  AnchoredRoot(std::string path, int fd, FileIdentity identity)
      : path_(std::move(path)), fd_(fd), identity_(identity) {}

  // Depth-first removal relative to `parent`, never following a link: a link is unlinked itself.
  static bool RemoveTree(int parent, const char* name) {
    const int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
      if (errno == ENOTDIR || errno == ELOOP) return unlinkat(parent, name, 0) == 0;
      return errno == ENOENT;
    }
    DIR* directory = fdopendir(fd);
    if (!directory) {
      close(fd);
      return false;
    }
    bool ok = true;
    while (dirent* entry = readdir(directory)) {
      const std::string child = entry->d_name;
      if (child == "." || child == "..") continue;
      struct stat info {};
      if (fstatat(dirfd(directory), entry->d_name, &info, AT_SYMLINK_NOFOLLOW) != 0) {
        ok = ok && errno == ENOENT;
        continue;
      }
      if (S_ISDIR(info.st_mode)) ok = RemoveTree(dirfd(directory), entry->d_name) && ok;
      else ok = (unlinkat(dirfd(directory), entry->d_name, 0) == 0 || errno == ENOENT) && ok;
    }
    closedir(directory);
    return (unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT) && ok;
  }

  const std::string path_;
  const int fd_;
  const FileIdentity identity_;
};

}  // namespace orbit_bridge

#endif  // ORBIT_BRIDGE_FILES_H
