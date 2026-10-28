#ifndef ORBIT_AUTHENTICATION_IMPORT_H
#define ORBIT_AUTHENTICATION_IMPORT_H
#include "OrbitAuthenticationABI.h"
#include <algorithm>
#include <functional>
#include <memory>
#include <set>
#include <string>
#include <tuple>
#include <vector>

namespace orbit_auth {
// Privileged native storage only. Copies in CEF/Swift cannot promise complete erasure.
struct Cookie {
  std::string host, name, path, value;
  bool host_only = true, secure = true, http_only = true, has_expiry = false;
  int same_site = 0, priority = 1;
  int source_scheme = 2, source_port = 443, source_type = 1;
  int64_t expiry = 0, creation = 0, access = 0, update = 0;
  auto Key() const { return std::tie(host, name, path); }
  bool SameProjection(const Cookie& b) const {
    return Key() == b.Key() && value == b.value && host_only == b.host_only && secure == b.secure
        && http_only == b.http_only && has_expiry == b.has_expiry && same_site == b.same_site
        && priority == b.priority && (!has_expiry || expiry == b.expiry);
  }
  ~Cookie() { volatile char* p = value.empty() ? nullptr : value.data(); for (size_t n = 0; n < value.size(); ++n) p[n] = 0; }
};

inline bool CopyBytes(ACRAuthBytes input, size_t limit, std::string& out) {
  if (input.length > limit || (input.length && !input.bytes)) return false;
  out.assign(input.length ? reinterpret_cast<const char*>(input.bytes) : "", input.length);
  return out.find('\0') == std::string::npos;
}

inline bool ValidCookie(const Cookie& c, int64_t now) {
  if (c.host.empty() || c.host.size() > 254 || c.name.empty() || c.name.size() > 1024 || c.path.empty()
      || c.path.size() > 1024 || c.name.size() + c.value.size() > 4096 || c.same_site < 0 || c.same_site > 3
      || c.priority < 0 || c.priority > 2 || c.host_only == c.host.starts_with('.')) return false;
  if (c.source_scheme != 2 || c.source_port != 443 || c.source_type < 1 || c.source_type > 3
      || c.creation < 0 || c.access < 0 || c.update < 0 || c.creation > 265046774399999999LL
      || c.access > 265046774399999999LL || c.update > 265046774399999999LL) return false;
  std::string host = c.host_only ? c.host : c.host.substr(1);
  if (!host.ends_with(".test") || host.size() > 253) return false;
  size_t start = 0;
  for (size_t n = 0; n <= host.size(); ++n) {
    if (n == host.size() || host[n] == '.') {
      if (n == start || n-start > 63 || host[start] == '-' || host[n-1] == '-') return false;
      start = n+1;
    } else if (!((host[n] >= 'a' && host[n] <= 'z') || (host[n] >= '0' && host[n] <= '9') || host[n] == '-')) return false;
  }
  const std::string separators = "()<>@,;:\\\"/[]?={} \t";
  for (unsigned char ch : c.name) if (ch < 33 || ch > 126 || separators.find(ch) != std::string::npos) return false;
  const std::string path_chars = "!$&'()*+,-./0123456789:=@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~";
  if (!c.path.starts_with('/') || c.path.starts_with("//")) return false;
  for (char ch : c.path) if (path_chars.find(ch) == std::string::npos) return false;
  std::string padded = c.path + "/";
  if (padded.find("/./") != std::string::npos || padded.find("/../") != std::string::npos) return false;
  for (unsigned char ch : c.value) if (!(ch == 0x21 || (ch >= 0x23 && ch <= 0x2b) || (ch >= 0x2d && ch <= 0x3a)
      || (ch >= 0x3c && ch <= 0x5b) || (ch >= 0x5d && ch <= 0x7e))) return false;
  std::string lower = c.name;
  for (char& ch : lower) if (ch >= 'A' && ch <= 'Z') ch += 'a'-'A';
  if ((lower.starts_with("__secure-") || lower.starts_with("__host-") || lower.starts_with("__http-")) && !c.secure) return false;
  if (lower.starts_with("__host-") && (!c.host_only || c.path != "/")) return false;
  if ((lower.starts_with("__http-") || lower.starts_with("__host-http-")) && !c.http_only) return false;
  if (c.same_site == 1 && !c.secure) return false;
  return now > 0 && (c.has_expiry ? (c.expiry > now && c.expiry <= 265046774399999999LL) : c.expiry == 0);
}

inline bool CopyBatch(const ACRAuthBatch* batch, int64_t now, std::vector<Cookie>& rows) {
  if (!batch || batch->struct_size != sizeof(*batch) || batch->version != ACR_AUTH_VERSION || !batch->operation
      || !batch->profile || batch->row_count > ACR_AUTH_MAX_ROWS || (batch->row_count && !batch->rows)
      || batch->timeout_ms < 10 || batch->timeout_ms > 30000) return false;
  size_t bytes = 0;
  for (uint32_t n = 0; n < batch->row_count; ++n) {
    const auto& in = batch->rows[n]; Cookie row;
    if (in.struct_size != sizeof(in) || in.version != ACR_AUTH_VERSION
        || !CopyBytes(in.host, 254, row.host) || !CopyBytes(in.name, 1024, row.name)
        || !CopyBytes(in.path, 1024, row.path) || !CopyBytes(in.value, 4096, row.value)) return false;
    for (int flag : {in.host_only, in.secure, in.http_only, in.has_expiry}) if (flag != 0 && flag != 1) return false;
    row.host_only = in.host_only; row.secure = in.secure; row.http_only = in.http_only;
    row.same_site = in.same_site; row.priority = in.priority; row.has_expiry = in.has_expiry; row.expiry = in.expiry_us;
    if (in.partitioned != 0) return false;
    row.source_scheme = in.source_scheme; row.source_port = in.source_port; row.source_type = in.source_type;
    row.creation = in.creation_us; row.access = in.last_access_us; row.update = in.last_update_us;
    if (!ValidCookie(row, now)) return false;
    bytes += row.host.size() + row.name.size() + row.path.size() + row.value.size();
    if (bytes > 327680) return false;
    for (const auto& prior : rows) if (prior.Key() == row.Key()) return false;
    rows.push_back(std::move(row));
  }
  return true;
}

// UI serialized transport. Completion: 0 success, 1 refused, 2 callback abandoned. A callback
// abandoned after a true return cannot attest drained writes; quarantine until shutdown.
struct Transport {
  using Done = std::function<void(int)>;
  using Visit = std::function<bool(const Cookie&, int, int)>;
  virtual ~Transport() = default;
  virtual bool Ready(Done) = 0;
  virtual bool Inventory(Visit, Done) = 0;
  virtual bool Set(const Cookie&, Done) = 0;
  virtual bool Flush(Done) = 0;
  virtual void DropNativeReferences() = 0;
};

class Operation : public std::enable_shared_from_this<Operation> {
 public:
  using Notice = std::function<void(const ACRAuthNotice&)>;
  using Clock = std::function<int64_t()>;
  Operation(uint64_t operation, uint64_t profile, std::vector<Cookie> rows, std::shared_ptr<Transport> transport,
      std::function<bool()> valid, Clock clock, Notice notice, std::function<void()> drained)
      : operation_(operation), profile_(profile), requested_(static_cast<uint32_t>(rows.size())), rows_(std::move(rows)),
        transport_(std::move(transport)), valid_(std::move(valid)), clock_(std::move(clock)),
        notice_(std::move(notice)), drained_(std::move(drained)) {}

  void Start() { Call([this](auto done) { return transport_->Ready(done); }, [this] { Inventory(true); }); }
  void Cancel() { Stop(ACR_AUTH_CANCELLED); }
  void Timeout() { Stop(ACR_AUTH_TIMEOUT); }
  bool drained() const { return drain_reported_; }
  void BeforeShutdown() {
    shutdown_preparing_ = true;
    Stop(ACR_AUTH_SHUTDOWN);
    if (transport_) transport_->DropNativeReferences();
  }
  // Only after CefShutdown returns (or the test transport's equivalent final barrier).
  void ShutdownComplete() {
    engine_stopped_ = true;
    pending_ = 0;
    Stop(ACR_AUTH_SHUTDOWN);
    Drain();
  }

 private:
  struct Receipt : std::enable_shared_from_this<Receipt> {
    std::shared_ptr<Operation> owner;
    std::function<void()> next;
    bool returned = false, accepted = false, fired = false, settled = false;
    bool flush = false, drain_flush = false;
    int result = 1;
    void Complete(int code) { if (fired || settled) return; fired = true; result = code; Settle(); }
    void Returned(bool value) { returned = true; accepted = value; Settle(); }
    void Settle() {
      if (!returned || settled || (accepted && !fired) || owner->engine_stopped_) return;
      settled = true;
      // A failed/abandoned cancellation flush cannot attest drainage. Retain its slot and
      // quarantine until the explicit final engine barrier; never report cleanup permission.
      if (drain_flush && (!accepted || result != 0)) return;
      if (accepted && result == 2) { owner->Stop(ACR_AUTH_ABANDONED); return; }
      --owner->pending_;
      if (accepted && result == 0 && flush) owner->flush_observed_ = true;
      if (!accepted || result != 0) owner->Stop(ACR_AUTH_CEF_REFUSED);
      else if (!owner->terminal_) {
        if (!owner->valid_()) owner->Stop(ACR_AUTH_CONTEXT_GONE);
        else next();
      }
      owner->Drain();
    }
  };
  template<typename Start> void Call(Start start, std::function<void()> next, bool flush = false) {
    if (terminal_) return;
    if (!valid_()) { Stop(ACR_AUTH_CONTEXT_GONE); return; }
    auto receipt = std::make_shared<Receipt>(); receipt->owner = shared_from_this(); receipt->next = std::move(next);
    receipt->flush = flush;
    ++pending_;
    const bool accepted = start([receipt](int code) { receipt->Complete(code); });
    receipt->Returned(accepted); // Early/duplicate callbacks cannot outrun the synchronous return.
  }
  void Inventory(bool initial) {
    observed_ = 0; seen_.clear();
    expected_total_ = -1;
    Call([this, initial](auto done) {
      auto self = shared_from_this();
      return transport_->Inventory([self, initial](const Cookie& cookie, int index, int total) {
        if (self->terminal_) return false;
        if (!self->valid_()) { self->Stop(ACR_AUTH_CONTEXT_GONE); return false; }
        if (total <= 0 || total > int(ACR_AUTH_MAX_ROWS) || index < 0 || index >= total || index != int(self->observed_)
            || (self->expected_total_ >= 0 && self->expected_total_ != total)) { self->Stop(ACR_AUTH_INVALID); return false; }
        self->expected_total_ = total;
        ++self->observed_;
        if (initial) { self->Stop(ACR_AUTH_NOT_EMPTY); return false; }
        auto key = std::make_tuple(cookie.host, cookie.name, cookie.path);
        if (!self->seen_.insert(key).second) { self->Stop(ACR_AUTH_AMBIGUOUS); return false; }
        bool matches = false;
        for (const auto& row : self->rows_) if (row.SameProjection(cookie)) { matches = true; break; }
        if (!matches || cookie.creation < 0 || cookie.access < 0) { self->Stop(ACR_AUTH_MISMATCH); return false; }
        return true;
      }, done);
    }, [this, initial] {
      if ((expected_total_ >= 0 && observed_ != uint32_t(expected_total_)) || (!initial && observed_ != rows_.size())) {
        Stop(ACR_AUTH_MISMATCH); return;
      }
      if (initial) SetNext(); else Stop(ACR_AUTH_SUBSET_MATCH);
    });
  }
  void SetNext() {
    if (installed_ == rows_.size()) {
      Call([this](auto done) { return transport_->Flush(done); }, [this] { Inventory(false); }, true); return;
    }
    if (!ValidCookie(rows_[installed_], clock_())) { Stop(ACR_AUTH_INVALID); return; } // Recheck expiry at apply.
    writes_started_ = true;
    Call([this](auto done) { Cookie borrowed = rows_[installed_]; return transport_->Set(borrowed, done); }, [this] { ++installed_; SetNext(); });
  }
  void Send(uint32_t kind) {
    if (!notice_) return;
    ACRAuthNotice result{sizeof(ACRAuthNotice), ACR_AUTH_VERSION, operation_, profile_, kind, status_,
                         requested_, installed_, observed_, pending_};
    auto callback = notice_; callback(result); // Reentrant cancellation may release the member callback.
  }
  void Stop(int status) {
    if (terminal_) return;
    terminal_ = true; status_ = status;
    rows_.clear(); seen_.clear(); // No future write after terminal; drop our secret copies now.
    if (!engine_stopped_ && ((writes_started_ && !flush_observed_) || status == ACR_AUTH_CONTEXT_GONE
        || status == ACR_AUTH_ABANDONED || status == ACR_AUTH_SHUTDOWN)) {
      drain_reserved_ = true; ++pending_; // Reserve a flush/final-shutdown barrier before the terminal is sent.
    }
    pending_at_terminal_ = pending_ != 0;
    Send(1); Drain();
  }
  void Drain() {
    if (!terminal_ || drain_reported_ || (shutdown_preparing_ && !engine_stopped_)) return;
    if (drain_reserved_) {
      if (engine_stopped_) drain_reserved_ = false;
      else if (flush_observed_) { drain_reserved_ = false; --pending_; }
      else if (pending_ == 1 && !drain_flush_started_ && status_ != ACR_AUTH_CONTEXT_GONE
          && status_ != ACR_AUTH_ABANDONED && status_ != ACR_AUTH_SHUTDOWN && valid_()) {
        drain_reserved_ = false; drain_flush_started_ = true;
        auto receipt = std::make_shared<Receipt>(); receipt->owner = shared_from_this(); receipt->next = [] {};
        receipt->flush = true; receipt->drain_flush = true;
        auto transport = transport_;
        const bool accepted = transport->Flush([receipt](int result) { receipt->Complete(result); });
        receipt->Returned(accepted); return;
      } else return;
    }
    if (pending_) return;
    drain_reported_ = true;
    if (pending_at_terminal_) Send(2);
    notice_ = {}; rows_.clear(); seen_.clear(); transport_.reset(); valid_ = {};
    auto done = std::move(drained_); if (done) done();
  }
  uint64_t operation_, profile_;
  uint32_t requested_, installed_ = 0, observed_ = 0, pending_ = 0;
  int expected_total_ = -1, status_ = ACR_AUTH_INVALID;
  bool terminal_ = false, pending_at_terminal_ = false, drain_reported_ = false, engine_stopped_ = false;
  bool writes_started_ = false, flush_observed_ = false, drain_reserved_ = false;
  bool drain_flush_started_ = false, shutdown_preparing_ = false;
  std::vector<Cookie> rows_;
  std::set<std::tuple<std::string, std::string, std::string>> seen_;
  std::shared_ptr<Transport> transport_;
  std::function<bool()> valid_;
  Clock clock_;
  Notice notice_;
  std::function<void()> drained_;
};
}
#endif
