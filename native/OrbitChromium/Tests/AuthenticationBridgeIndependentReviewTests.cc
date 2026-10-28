// Exact-source, offline review regressions. No CEF framework or application runtime.
#include "OrbitAuthenticationCEF.h"
#include "OrbitAuthenticationFiles.h"
#include <cassert>
#include <cstdio>
#include <map>

using namespace orbit_auth;
constexpr int64_t kReviewNow = 13437446400000000LL;

Cookie ReviewRow() {
  Cookie c;
  c.host = "review.fixture.test"; c.name = "review"; c.path = "/";
  c.value = "public-synthetic-review";
  return c;
}

// Independent transport: each native request stays pending until the test settles it.
struct ReviewTransport final : Transport {
  Done ready, inventory, setter, flush;
  Visit visit;
  unsigned sets = 0, flushes = 0, drops = 0;
  int earlyFalseStage = 0;
  bool Ready(Done cb) override {
    if (earlyFalseStage == 1) { cb(0); return false; }
    ready = std::move(cb); return true;
  }
  bool Inventory(Visit v, Done cb) override {
    if (earlyFalseStage == 2) { cb(0); return false; }
    visit = std::move(v); inventory = std::move(cb); return true;
  }
  bool Set(const Cookie&, Done cb) override {
    ++sets;
    if (earlyFalseStage == 3) { cb(0); return false; }
    setter = std::move(cb); return true;
  }
  bool Flush(Done cb) override {
    ++flushes;
    if (earlyFalseStage == 4) { cb(0); return false; }
    flush = std::move(cb); return true;
  }
  void DropNativeReferences() override { ++drops; }
  static void Complete(Done& slot, int status = 0) {
    auto cb = std::move(slot); slot = {}; assert(cb); cb(status);
  }
};

struct ReviewOperation {
  std::shared_ptr<ReviewTransport> transport = std::make_shared<ReviewTransport>();
  std::vector<ACRAuthNotice> notices;
  std::shared_ptr<Operation> operation;
  bool valid = true;
  int64_t now = kReviewNow;
  unsigned drained = 0;
  std::function<void()> onTerminal;
  explicit ReviewOperation(std::vector<Cookie> rows = {ReviewRow()}, std::shared_ptr<ReviewTransport> custom = {}) {
    if (custom) transport = std::move(custom);
    operation = std::make_shared<Operation>(91, 92, std::move(rows), transport,
        [this] { return valid; }, [this] { return now; },
        [this](const ACRAuthNotice& n) {
          notices.push_back(n);
          if (n.kind == 1 && onTerminal) onTerminal();
        }, [this] { ++drained; });
    operation->Start();
  }
  void ReachSetter() {
    ReviewTransport::Complete(transport->ready);
    ReviewTransport::Complete(transport->inventory);
    assert(transport->sets == 1);
  }
  void FinalBarrier() { operation->BeforeShutdown(); operation->ShutdownComplete(); }
  void Check(unsigned count, int status, bool isDrained) {
    assert(notices.size() == count && notices[0].kind == 1 && notices[0].status == status);
    assert(operation->drained() == isDrained && drained == unsigned(isDrained));
    for (size_t i = 1; i < notices.size(); ++i) {
      assert(notices[i].kind == 2 && notices[i].pending == 0 && notices[i].status == status);
    }
  }
};

void ReviewFalseReturnWins() {
  for (int stage = 1; stage <= 4; ++stage) {
    auto transport = std::make_shared<ReviewTransport>(); transport->earlyFalseStage = stage;
    ReviewOperation f({ReviewRow()}, transport);
    if (stage > 1) ReviewTransport::Complete(transport->ready);
    if (stage > 2) ReviewTransport::Complete(transport->inventory);
    if (stage > 3) ReviewTransport::Complete(transport->setter);
    f.Check(1, ACR_AUTH_CEF_REFUSED, stage < 3);
    if (stage == 3) {
      assert(f.notices[0].installed == 0);
      ReviewTransport::Complete(transport->flush);
      f.Check(2, ACR_AUTH_CEF_REFUSED, true);
    }
    if (stage == 4) { f.FinalBarrier(); f.Check(2, ACR_AUTH_CEF_REFUSED, true); }
    assert(transport->sets == unsigned(stage >= 3));
  }
}

void ReviewLateCallbacksAndAbandonedDispatch() {
  for (bool failure : {false, true}) {
    ReviewOperation f; f.ReachSetter();
    auto late = f.transport->setter;
    f.operation->Timeout(); f.operation->Cancel();
    f.Check(1, ACR_AUTH_TIMEOUT, false);
    ReviewTransport::Complete(f.transport->setter, failure ? 1 : 0);
    // A late confirmed setter must not inflate the already published installed count.
    assert(f.notices[0].installed == 0 && f.transport->sets == 1 && f.transport->flushes == 1);
    auto lateFlush = f.transport->flush;
    ReviewTransport::Complete(f.transport->flush);
    f.Check(2, ACR_AUTH_TIMEOUT, true);
    late(0); late(2); lateFlush(0); f.operation->Timeout();
    f.Check(2, ACR_AUTH_TIMEOUT, true);
  }
  // A callback task accepted by dispatch but later discarded never grants drain.
  ReviewOperation lost; lost.ReachSetter(); lost.operation->Cancel();
  auto late = lost.transport->setter;
  lost.transport->setter = {}; // Equivalent to dropping the dispatched completion closure.
  lost.Check(1, ACR_AUTH_CANCELLED, false);
  lost.FinalBarrier(); lost.Check(2, ACR_AUTH_CANCELLED, true);
  late(0); late(2); lost.Check(2, ACR_AUTH_CANCELLED, true);
  assert(lost.transport->flushes == 0 && lost.transport->drops == 1);
}

void ReviewInventoryAndReentrance() {
  ReviewOperation cancelled;
  cancelled.onTerminal = [&] { cancelled.operation->Cancel(); cancelled.operation->Timeout(); };
  ReviewTransport::Complete(cancelled.transport->ready);
  cancelled.operation->Cancel(); cancelled.Check(1, ACR_AUTH_CANCELLED, false);
  // CEF may still offer a cookie after cancellation; it must stop without a write.
  assert(!cancelled.transport->visit(ReviewRow(), 0, 1));
  ReviewTransport::Complete(cancelled.transport->inventory);
  cancelled.Check(2, ACR_AUTH_CANCELLED, true);
  assert(cancelled.transport->sets == 0);

  ReviewOperation gone({});
  ReviewTransport::Complete(gone.transport->ready);
  gone.valid = false;
  ReviewTransport::Complete(gone.transport->inventory);
  gone.Check(1, ACR_AUTH_CONTEXT_GONE, false);
  gone.FinalBarrier(); gone.Check(2, ACR_AUTH_CONTEXT_GONE, true);

  auto expiring = ReviewRow(); expiring.has_expiry = true; expiring.expiry = kReviewNow + 1;
  ReviewOperation expired({expiring});
  ReviewTransport::Complete(expired.transport->ready);
  expired.now = expiring.expiry;
  ReviewTransport::Complete(expired.transport->inventory);
  expired.Check(1, ACR_AUTH_INVALID, true); assert(expired.transport->sets == 0);

  // Claimed total cannot silently shrink, even when the observed row matches.
  ReviewOperation partial; partial.ReachSetter();
  ReviewTransport::Complete(partial.transport->setter);
  ReviewTransport::Complete(partial.transport->flush);
  assert(partial.transport->visit(ReviewRow(), 0, 2));
  ReviewTransport::Complete(partial.transport->inventory);
  partial.Check(1, ACR_AUTH_MISMATCH, true);
}

void ReviewCallbacksAndPublicProjection() {
  std::vector<std::function<void()>> queue;
  auto dispatch = [&](std::function<void()> cb) { queue.push_back(std::move(cb)); };
  std::vector<int> results;
  auto done = [&](int result) { results.push_back(result); };
  { CefRefPtr<DoneCallback> cb = new DoneCallback(done, dispatch); cb->OnComplete(); cb->OnComplete(); }
  assert(results.empty() && queue.size() == 1); queue[0](); queue.clear();
  assert(results == std::vector<int>{0}); results.clear();
  { CefRefPtr<SetCallback> cb = new SetCallback(done, dispatch); }
  assert(queue.size() == 1); queue[0](); queue.clear();
  assert(results == std::vector<int>{2}); results.clear();
  { CefRefPtr<Visitor> cb = new Visitor([](const Cookie&, int, int) { assert(false); return false; }, done, dispatch); }
  assert(results.empty() && queue.size() == 1); queue[0](); queue.clear();
  assert(results == std::vector<int>{0}); // Empty visitor alone is a transport result, not operation success.

  CefCookie raw;
  CefString(&raw.domain) = "review.fixture.test"; CefString(&raw.name) = "review";
  CefString(&raw.path) = "/"; CefString(&raw.value) = "public-synthetic-review";
  raw.secure = 1; raw.httponly = 1;
  for (int sql = 0; sql != 3; ++sql) {
    cef_cookie_priority_t priority; assert(PriorityToCEF(sql, priority));
    assert(int(priority) == sql - 1);
    raw.priority = priority;
    for (int site = 0; site != 4; ++site) {
      raw.same_site = static_cast<cef_cookie_same_site_t>(site);
      Cookie projected; assert(ReadCEF(raw, projected));
      assert(projected.priority == sql && projected.same_site == site && projected.host_only);
    }
  }
  Cookie rejected; raw.size--; assert(!ReadCEF(raw, rejected)); raw.size++;
  raw.secure = -1; assert(!ReadCEF(raw, rejected)); raw.secure = 1;
  raw.has_expires = 0; raw.expires.val = 1; assert(!ReadCEF(raw, rejected)); raw.expires.val = 0;
  raw.last_access.val = 265046774400000000LL; assert(!ReadCEF(raw, rejected));
}

void ReviewAggregateBounds() {
  std::vector<Cookie> cookies(64, ReviewRow());
  std::vector<ACRAuthCookie> input;
  auto bytes = [](const std::string& s) { return ACRAuthBytes{reinterpret_cast<const uint8_t*>(s.data()), uint32_t(s.size())}; };
  for (size_t i = 0; i != cookies.size(); ++i) {
    auto& row = cookies[i];
    row.name = "row" + std::to_string(i);
    row.value.assign(4096 - row.name.size(), 'a');
    row.path = "/" + std::string(1023, 'p');
    ACRAuthCookie c{}; c.struct_size = sizeof(c); c.version = ACR_AUTH_VERSION;
    c.host = bytes(row.host); c.name = bytes(row.name); c.value = bytes(row.value); c.path = bytes(row.path);
    c.host_only = c.secure = c.http_only = 1; c.priority = 1;
    c.source_scheme = 2; c.source_port = 443; c.source_type = 1;
    input.push_back(c);
  }
  ACRAuthBatch batch{sizeof(ACRAuthBatch), ACR_AUTH_VERSION, 1, 2, input.data(), 64, 10};
  std::vector<Cookie> copied;
  assert(!CopyBatch(&batch, kReviewNow, copied)); // Each row is legal; aggregate exceeds 327680.
  batch.row_count = 63; copied.clear(); assert(CopyBatch(&batch, kReviewNow, copied));
}

int main() {
  ReviewFalseReturnWins(); ReviewLateCallbacksAndAbandonedDispatch(); ReviewInventoryAndReentrance();
  ReviewCallbacksAndPublicProjection(); ReviewAggregateBounds();
  puts("PASS independent bridge review: five adversarial groups, actual production headers, offline only");
}
