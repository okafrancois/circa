#ifndef ORBIT_AUTHENTICATION_CEF_H
#define ORBIT_AUTHENTICATION_CEF_H
#include "OrbitAuthenticationImport.h"
#include "include/cef_cookie.h"
#include "include/cef_request_context.h"
#include <atomic>

namespace orbit_auth {
// Shared production resolver, instantiated with real CefRequestContext references in the
// bridge and typed context doubles in offline tests. Mapping intent alone is never admission.
template<class Contexts, class Directories, class Ready>
typename Contexts::mapped_type ResolveContext(uint64_t profile, const Contexts& contexts,
    const Directories& directories, const Ready& ready, typename Contexts::mapped_type global) {
  const auto target = directories.find(profile);
  const auto found = contexts.find(profile);
  if (!profile || !ready.contains(profile) || target == directories.end() || found == contexts.end()
      || !target->second->Anchored() || !found->second || found->second->IsGlobal()
      || found->second->GetCachePath().ToString() != target->second->path() || !global
      || found->second->IsSharingWith(global)) return {};
  for (const auto& [other, context] : contexts)
    if (other != profile && (!context || found->second->IsSharingWith(context))) return {};
  return found->second;
}
// All entry points and scheduled completions are UI serialized. Destructors may be released by
// CEF elsewhere: dispatch transfers their native receipt to the UI owner; failed dispatch leaves
// the operation quarantined until the explicit post-CefShutdown barrier.
using Dispatch = std::function<void(std::function<void()>)>;
class DoneCallback final : public CefCompletionCallback {
 public:
  DoneCallback(Transport::Done done, Dispatch dispatch) : done_(std::move(done)), dispatch_(std::move(dispatch)) {}
  void OnComplete() override { if (fired_.exchange(true)) return; auto done = done_; auto dispatch = dispatch_; dispatch([done] { done(0); }); }
  ~DoneCallback() override { if (!fired_) { auto done = done_; dispatch_([done] { done(2); }); } }
 private:
  Transport::Done done_; Dispatch dispatch_; std::atomic<bool> fired_{false};
  IMPLEMENT_REFCOUNTING(DoneCallback);
};
class SetCallback final : public CefSetCookieCallback {
 public:
  SetCallback(Transport::Done done, Dispatch dispatch) : done_(std::move(done)), dispatch_(std::move(dispatch)) {}
  void OnComplete(bool success) override { if (fired_.exchange(true)) return; auto done = done_; auto dispatch = dispatch_; dispatch([done, success] { done(success ? 0 : 1); }); }
  ~SetCallback() override { if (!fired_) { auto done = done_; dispatch_([done] { done(2); }); } }
 private:
  Transport::Done done_; Dispatch dispatch_; std::atomic<bool> fired_{false};
  IMPLEMENT_REFCOUNTING(SetCallback);
};
inline bool PriorityToCEF(int sql, cef_cookie_priority_t& cef) {
  switch (sql) {
    case 0: cef = CEF_COOKIE_PRIORITY_LOW; return true;
    case 1: cef = CEF_COOKIE_PRIORITY_MEDIUM; return true;
    case 2: cef = CEF_COOKIE_PRIORITY_HIGH; return true;
    default: return false;
  }
}
inline bool PriorityFromCEF(cef_cookie_priority_t cef, int& sql) {
  switch (cef) {
    case CEF_COOKIE_PRIORITY_LOW: sql = 0; return true;
    case CEF_COOKIE_PRIORITY_MEDIUM: sql = 1; return true;
    case CEF_COOKIE_PRIORITY_HIGH: sql = 2; return true;
    default: return false;
  }
}
inline bool ReadCEF(const CefCookie& raw, Cookie& out) {
  if (raw.size != sizeof(cef_cookie_t) || !PriorityFromCEF(raw.priority, out.priority)) return false;
  for (const auto* str : {&raw.domain, &raw.name, &raw.path, &raw.value}) {
    if (str->length > 4096 || (str->length && !str->str)) return false;
    for (size_t n = 0; n < str->length; ++n) if (!str->str[n] || str->str[n] > 127) return false;
  }
  for (int flag : {raw.secure, raw.httponly, raw.has_expires}) if (flag != 0 && flag != 1) return false;
  if (raw.same_site < 0 || raw.same_site > 3
      || raw.creation.val < 0 || raw.last_access.val < 0 || raw.expires.val < 0
      || raw.creation.val > 265046774399999999LL || raw.last_access.val > 265046774399999999LL
      || raw.expires.val > 265046774399999999LL || (!raw.has_expires && raw.expires.val != 0)) return false;
  out.host = CefString(&raw.domain).ToString(); out.name = CefString(&raw.name).ToString();
  out.path = CefString(&raw.path).ToString(); out.value = CefString(&raw.value).ToString();
  out.host_only = !out.host.starts_with('.'); out.secure = raw.secure; out.http_only = raw.httponly;
  out.has_expiry = raw.has_expires; out.expiry = raw.expires.val;
  out.same_site = raw.same_site;
  out.creation = raw.creation.val; out.access = raw.last_access.val;
  return out.host.size() <= 254 && out.name.size() <= 1024 && out.path.size() <= 1024 && out.value.size() <= 4096;
}
class Visitor final : public CefCookieVisitor {
 public:
  Visitor(Transport::Visit visit, Transport::Done done, Dispatch dispatch)
      : visit_(std::move(visit)), done_(std::move(done)), dispatch_(std::move(dispatch)) {}
  bool Visit(const CefCookie& raw, int index, int total, bool& remove) override {
    remove = false;
    Cookie cookie;
    if (!ReadCEF(raw, cookie)) { failed_ = true; return false; }
    return visit_(cookie, index, total);
  }
  ~Visitor() override { auto done = done_; bool failed = failed_; dispatch_([done, failed] { done(failed ? 1 : 0); }); }
 private:
  Transport::Visit visit_; Transport::Done done_; Dispatch dispatch_; bool failed_ = false;
  IMPLEMENT_REFCOUNTING(Visitor);
};

class CEFTransport final : public Transport {
 public:
  using ManagerFactory = std::function<CefRefPtr<CefCookieManager>(CefRefPtr<CefCompletionCallback>)>;
  CEFTransport(std::shared_ptr<void> context_retention, ManagerFactory factory, Dispatch dispatch)
      : context_(std::move(context_retention)), factory_(std::move(factory)), dispatch_(std::move(dispatch)) {}
  bool Ready(Done done) override {
    // Factory may invoke ready before returning. Core receipts defer advancement until this
    // call has returned and the manager has been assigned.
    manager_ = factory_(new DoneCallback(std::move(done), dispatch_));
    factory_ = {}; // Factory may also retain the request context.
    return manager_ != nullptr;
  }
  bool Inventory(Visit visit, Done done) override {
    return manager_ && manager_->VisitAllCookies(new Visitor(std::move(visit), std::move(done), dispatch_));
  }
  bool Set(const Cookie& row, Done done) override {
    if (!manager_) return false;
    CefCookie cookie;
    CefString(&cookie.name) = row.name; CefString(&cookie.value) = row.value;
    CefString(&cookie.domain) = row.host_only ? "" : row.host;
    CefString(&cookie.path) = row.path;
    cookie.secure = row.secure; cookie.httponly = row.http_only;
    cookie.same_site = static_cast<cef_cookie_same_site_t>(row.same_site);
    if (!PriorityToCEF(row.priority, cookie.priority)) return false;
    cookie.has_expires = row.has_expiry; cookie.expires.val = row.expiry;
    std::string host = row.host_only ? row.host : row.host.substr(1);
    return manager_->SetCookie("https://" + host + row.path, cookie, new SetCallback(std::move(done), dispatch_));
  }
  bool Flush(Done done) override { return manager_ && manager_->FlushStore(new DoneCallback(std::move(done), dispatch_)); }
  void DropNativeReferences() override { factory_ = {}; manager_ = nullptr; context_.reset(); }
 private:
  std::shared_ptr<void> context_;
  ManagerFactory factory_;
  CefRefPtr<CefCookieManager> manager_;
  Dispatch dispatch_;
};
}
#endif
