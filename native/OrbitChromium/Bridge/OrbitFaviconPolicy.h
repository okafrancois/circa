#ifndef ORBIT_FAVICON_POLICY_H
#define ORBIT_FAVICON_POLICY_H
#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>
namespace orbit_bridge {
// UI-thread-only receipt ledger. No borrowed host or CEF object survives a callback.
struct FaviconReceipt {
  uint64_t epoch = 0;
  unsigned requests = 0;
  bool active = false;
  std::vector<std::string> candidates;
  void Reset() { ++epoch; requests = 0; candidates.clear(); }
  static bool Allowed(const std::string& url) {
    return url.size() <= 8192 && (url.starts_with("https://") || url.starts_with("http://") ||
      (url.size() <= 8192 && url.starts_with("data:image/")));
  }
  void Announce(const std::vector<std::string>& urls) {
    ++epoch;
    candidates.clear();
    for (const auto& url : urls) {
      if (Allowed(url) && candidates.size() < 4 &&
          std::find(candidates.begin(), candidates.end(), url) == candidates.end()) candidates.push_back(url);
    }
  }
  bool CanStart(unsigned outstanding) const {
    return !active && requests < 8 && outstanding < 8 && !candidates.empty();
  }
  bool Accept(uint64_t captured_epoch, const std::string& url) const {
    return captured_epoch == epoch && !candidates.empty() && candidates.front() == url;
  }
  static bool Bounded(int width, int height, size_t bytes) {
    return width > 0 && height > 0 && width <= 128 && height <= 128 && bytes > 0 && bytes <= 131072;
  }
};
// Shared by the real CEF callback and a fake-image unit fixture. CEF is the only decoder;
// this boundary extracts only a small already-decoded representation, never arbitrary bytes.
template <typename ImagePointer>
std::vector<unsigned char> ExtractFaviconPNG(ImagePointer image, bool exact_url, int status) {
  if (!exact_url || !(status == 0 || (status >= 200 && status < 300)) || !image ||
      image->GetWidth() > 64 || image->GetHeight() > 64) return {};
  int width = 0, height = 0;
  float scale = 0;
  if (!image->GetRepresentationInfo(1.0f, scale, width, height) ||
      !FaviconReceipt::Bounded(width, height, 1)) return {};
  auto png = image->GetAsPNG(1.0f, true, width, height);
  if (!png || !FaviconReceipt::Bounded(width, height, png->GetSize())) return {};
  std::vector<unsigned char> bytes(png->GetSize());
  if (png->GetData(bytes.data(), bytes.size(), 0) != bytes.size()) return {};
  return bytes;
}
}
#endif
