#ifndef ORBIT_AUTHENTICATION_FILES_H
#define ORBIT_AUTHENTICATION_FILES_H
#include "OrbitBridgeFiles.h"
#include <cstring>

namespace orbit_auth {
// Consume the sole ordinary-profile creation entrance before CEF can call back reentrantly.
// Nested attempts (even using the same token) cannot borrow the fresh target's admission.
class CreationGate {
 public:
  bool active() const { return token_ != 0; }
  bool Begin(uint64_t token) { if (!token || active()) return false; token_=token; unused_=true; return true; }
  bool Enter(uint64_t token) {
    if (!active()) return true;
    if (token != token_ || !unused_) return false;
    unused_=false; return true;
  }
  bool Owns(uint64_t token) const { return active() && token_ == token && !unused_; }
  void End() { token_=0; unused_=false; }
 private:
  uint64_t token_=0;
  bool unused_=false;
};
// The synthetic harness must explicitly mark its private root before starting CEF. No personal
// root is auto-marked. Holding descriptors detects replacement, not a hostile same-UID writer.
class FreshDirectory {
 public:
  static bool SyntheticRoot(const orbit_bridge::AnchoredRoot& root) {
    if (!root.StillAtPath()) return false;
    struct stat info{};
    if (fstat(root.fd(), &info) || info.st_uid != geteuid() || (info.st_mode & 0777) != 0700) return {};
    int marker = openat(root.fd(), ".orbit-auth-synthetic", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (marker < 0) return {};
    char text[32]{};
    const bool marked = !fstat(marker, &info) && S_ISREG(info.st_mode) && info.st_nlink == 1 && info.st_uid == geteuid()
        && (info.st_mode & 0777) == 0600 && info.st_size == 23 && read(marker, text, sizeof(text)) == 23
        && std::string(text, 23) == "orbit-auth-synthetic-v1\n";
    close(marker);
    return marked;
  }
  static std::shared_ptr<FreshDirectory> Create(const orbit_bridge::AnchoredRoot& root, const std::string& name) {
    if (!SyntheticRoot(root) || !name.starts_with("Auth-") || name.size() < 6 || name.size() > 80) return {};
    for (char c : name) if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-')) return {};
    if (mkdirat(root.fd(), name.c_str(), 0700)) return {}; // EEXIST always refuses.
    struct stat info{};
    int child = openat(root.fd(), name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (child < 0) return {}; // Retain uncertain entries; never delete a replacement.
    if (fstat(child, &info) || !S_ISDIR(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 0777) != 0700) {
      close(child); return {};
    }
    auto lease = std::shared_ptr<FreshDirectory>(new FreshDirectory(root.path(), name, fcntl(root.fd(), F_DUPFD_CLOEXEC, 0), child,
        root.identity(), {info.st_dev, info.st_ino}));
    if (lease->root_fd_ < 0 || !lease->Anchored() || !lease->Empty()) return {};
    return lease;
  }
  ~FreshDirectory() { if (root_fd_ >= 0) close(root_fd_); close(child_fd_); }
  const std::string path() const { return root_ + "/" + name_; }
  bool Anchored() const {
    auto root = orbit_bridge::AnchoredRoot::Open(root_);
    struct stat info{}, root_info{};
    return root && root->identity() == root_identity_ && !fstat(root_fd_, &root_info)
        && root_info.st_uid == geteuid() && (root_info.st_mode & 0777) == 0700
        && !fstatat(root_fd_, name_.c_str(), &info, AT_SYMLINK_NOFOLLOW)
        && S_ISDIR(info.st_mode) && info.st_uid == geteuid() && (info.st_mode & 0777) == 0700
        && orbit_bridge::FileIdentity{info.st_dev, info.st_ino} == child_identity_;
  }
  bool Empty() const {
    int copy = openat(child_fd_, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (copy < 0) return false;
    DIR* dir = fdopendir(copy);
    if (!dir) { close(copy); return false; }
    bool empty = true;
    errno = 0;
    while (auto* entry = readdir(dir)) if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) { empty = false; break; }
    if (errno) empty = false;
    closedir(dir);
    return empty;
  }
 private:
  FreshDirectory(std::string root, std::string name, int root_fd, int child_fd,
      orbit_bridge::FileIdentity root_identity, orbit_bridge::FileIdentity child_identity)
      : root_(std::move(root)), name_(std::move(name)), root_fd_(root_fd), child_fd_(child_fd),
        root_identity_(root_identity), child_identity_(child_identity) {}
  std::string root_, name_;
  int root_fd_, child_fd_;
  orbit_bridge::FileIdentity root_identity_, child_identity_;
};
}
#endif
