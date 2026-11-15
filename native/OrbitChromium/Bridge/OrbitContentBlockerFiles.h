// The bundled extension is immutable. Chromium's generated DNR indexes belong to the
// engine data root. Publish a complete, content-addressed copy before initializing CEF.
#ifndef ORBIT_CONTENT_BLOCKER_FILES_H
#define ORBIT_CONTENT_BLOCKER_FILES_H
#include "OrbitBridgeFiles.h"
#include <CommonCrypto/CommonDigest.h>
#include <array>
#include <vector>

namespace orbit_bridge {
namespace content_blocker {
inline constexpr std::array<const char*, 4> files = {
    "manifest.json", "rulesets/easylist.json", "rulesets/easyprivacy.json", "rulesets/LICENSE.md"};

// Both directory components and leaves must be real, private copies, never symlinks.
inline int OpenFile(int directory, const char* name, int flags) {
  const std::string path(name);
  const auto slash = path.find('/');
  if (slash == std::string::npos) return openat(directory, name, flags | O_NOFOLLOW | O_CLOEXEC, 0600);
  int child = openat(directory, path.substr(0, slash).c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (child < 0) return -1;
  int fd = openat(child, path.substr(slash + 1).c_str(), flags | O_NOFOLLOW | O_CLOEXEC, 0600);
  close(child);
  return fd;
}
inline bool Read(int directory, const char* name, std::string& bytes) {
  int fd = OpenFile(directory, name, O_RDONLY);
  if (fd < 0) return false;
  struct stat st {};
  bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size >= 0 && st.st_size <= 32 * 1024 * 1024;
  bytes.clear();
  char buffer[16384];
  while (ok) {
    ssize_t size = read(fd, buffer, sizeof(buffer));
    if (size < 0 && errno == EINTR) continue;
    if (size <= 0) { ok = size == 0; break; }
    bytes.append(buffer, size);
    if (bytes.size() > 32 * 1024 * 1024) ok = false;
  }
  close(fd);
  return ok;
}
inline bool Matches(const AnchoredRoot& directory, const std::array<std::string, 5>& contents) {
  for (size_t i = 0; i < files.size(); ++i) {
    std::string bytes;
    if (!Read(directory.fd(), files[i], bytes) || bytes != contents[i]) return false;
  }
  return true;
}
}  // namespace content_blocker

// Empty means startup must fail, never fall back to loading from the signed bundle.
inline std::string StageContentBlocker(const AnchoredRoot& root, const std::string& source) {
  using namespace content_blocker;
  // Foundation abbreviates /private/tmp to /tmp even after resolving symlinks.
  // Canonicalize the trusted bundle source with the same POSIX rules as AnchoredRoot.
  char resolved[PATH_MAX];
  if (!realpath(source.c_str(), resolved)) return {};
  auto bundled = AnchoredRoot::Open(resolved);
  if (!bundled || !root.StillAtPath() || root.path().find(',') != std::string::npos) return {};
  std::array<std::string, 5> contents;
  CC_SHA256_CTX hash;
  CC_SHA256_Init(&hash);
  for (size_t i = 0; i < files.size(); ++i) {
    if (!Read(bundled->fd(), files[i], contents[i])) return {};
    const uint64_t size = contents[i].size();
    CC_SHA256_Update(&hash, &size, sizeof(size));
    CC_SHA256_Update(&hash, contents[i].data(), static_cast<CC_LONG>(size));
  }
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &hash);
  std::string version = "v1-";
  for (auto byte : digest) { version += "0123456789abcdef"[byte >> 4]; version += "0123456789abcdef"[byte & 15]; }
  if (mkdirat(root.fd(), "ContentBlocking", 0700) != 0 && errno != EEXIST) return {};
  auto cache = AnchoredRoot::Open(root.path() + "/ContentBlocking");
  if (!cache) return {};
  const std::string destination = cache->path() + "/" + version;
  if (auto existing = AnchoredRoot::Open(destination)) {
    // Preserve valid generated indexes. Never silently use changed extension code.
    return Matches(*existing, contents) ? destination : std::string();
  }
  if (cache->Inspect(version) != AnchoredRoot::Entry::kAbsent) return {};
  char temporary[64];
  snprintf(temporary, sizeof(temporary), ".stage-%08x%08x", arc4random(), arc4random());
  if (mkdirat(cache->fd(), temporary, 0700) != 0) return {};
  bool ok = false;
  {
    auto staging = AnchoredRoot::Open(cache->path() + "/" + temporary);
    if (staging && mkdirat(staging->fd(), "rulesets", 0700) == 0) {
      ok = true;
      for (size_t i = 0; i < files.size() && ok; ++i) {
        int fd = OpenFile(staging->fd(), files[i], O_WRONLY | O_CREAT | O_EXCL);
        if (fd < 0) { ok = false; break; }
        size_t offset = 0;
        while (offset < contents[i].size()) {
          ssize_t size = write(fd, contents[i].data() + offset, contents[i].size() - offset);
          if (size < 0 && errno == EINTR) continue;
          if (size <= 0) { ok = false; break; }
          offset += size;
        }
        if (fsync(fd) != 0) ok = false;
        close(fd);
      }
      // The version is visible to Chromium only after every file is complete. Another
      // launcher may publish the identical version first; reuse it after verification.
      if (ok && root.StillAtPath() && cache->StillAtPath()) {
        if (renameat(cache->fd(), temporary, cache->fd(), version.c_str()) != 0) {
          auto winner = AnchoredRoot::Open(destination);
          ok = winner && Matches(*winner, contents);
        }
      } else { ok = false; }
    }
  }
  cache->RemoveChild(temporary);
  return ok ? destination : std::string();
}
}  // namespace orbit_bridge
#endif
