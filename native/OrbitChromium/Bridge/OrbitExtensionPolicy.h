// Copyright 2026 Orbit. BSD-style license; see LICENSE.
#ifndef ORBIT_EXTENSION_POLICY_H_
#define ORBIT_EXTENSION_POLICY_H_
#include <optional>
#include <string>
#include <string_view>
namespace orbit_bridge {
inline bool ValidExtensionID(const char* id) {
  if (!id) return false;
  const std::string_view value(id);
  if (value.size() != 32) return false;
  for (char c : value) if (c < 'a' || c > 'p') return false;
  return true;
}
// Authority exists only following an explicit native command. Any main-frame
// attempt consumes the grant; redirects, POST and other internal routes fail.
// A grant names one exact manager document: the manager itself, one
// extension's details (EXT-OUTCOME-R2) or the keyboard-shortcut page. Only that
// document, and a reload of the trusted current one, is allowed.
class ExtensionManagerRoute {
 public:
  static constexpr const char* kURL = "chrome://extensions/";
  static constexpr const char* kShortcutsURL = "chrome://extensions/shortcuts";
  static constexpr const char* kDetailsPrefix = "chrome://extensions/?id=";
  enum Page : int { kManager = 0, kDetails = 1, kShortcuts = 2 };
  // The exact document of a native command, or nullopt (unknown page, invalid ID).
  static std::optional<std::string> Target(int page, const char* extension_id) {
    if (page == kManager) return std::string(kURL);
    if (page == kShortcuts) return std::string(kShortcutsURL);
    if (page == kDetails && ValidExtensionID(extension_id)) return kDetailsPrefix + std::string(extension_id);
    return std::nullopt;
  }
  void Arm(std::string_view target = kURL) { armed_ = std::string(target); }
  bool Allow(std::string_view target, std::string_view current,
             bool redirect, std::string_view method) {
    const std::optional<std::string> armed = std::move(armed_);
    armed_.reset();
    const bool allow = !redirect && method == "GET" &&
        ((armed && target == *armed) || (trusted_ && target == *trusted_ && current == *trusted_));
    if (allow) trusted_ = std::string(target);
    else trusted_.reset();
    return allow;
  }
 private:
  std::optional<std::string> armed_;
  std::optional<std::string> trusted_;
};
}
#endif
