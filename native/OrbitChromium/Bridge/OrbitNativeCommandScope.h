#ifndef ORBIT_NATIVE_COMMAND_SCOPE_H
#define ORBIT_NATIVE_COMMAND_SCOPE_H

#include <cstdint>
#include <cstdio>
#include <deque>
#include <functional>
#include <utility>
#include <unordered_map>

namespace orbit_bridge {

// UI-thread command scope: creation callbacks may publish a surface while the
// native tab strip is mutating, but activation must wait for a later loop turn.
class NativeCommandScope {
 public:
  class Command {
   public:
    explicit Command(NativeCommandScope& scope) : scope_(scope) { ++scope_.depth_; }
    ~Command() { scope_.Leave(); }
    Command(const Command&) = delete;
    Command& operator=(const Command&) = delete;
   private:
    NativeCommandScope& scope_;
  };

  using Action = std::function<int32_t()>;
  using Post = std::function<bool(std::function<void()>)>;
  using Trace = std::function<void(uint64_t, const char*)>;

  // Runtime shutdown must release parked native browser references before CEF ends.
  void Cancel() { cancelled_ = true; parked_.clear(); }

  int32_t ActivateOrDefer(Action action, const Post& post, uint64_t window = 0, Trace trace = {}) {
    if (cancelled_) { if (trace) trace(0, "cancelled"); return 0; }
    // A delayed activation must not overwrite a newer accepted selection in the same window.
    // Other windows retain their own intent, and a refused post does not revoke older work.
    const auto previous = window ? latest_[window] : 0;
    const auto ticket = window ? ++next_ticket_ : 0;
    if (window) {
      latest_[window] = ticket;
      action = [this, window, ticket, trace, run = std::move(action)] {
        if (latest_[window] != ticket) {
          if (trace) trace(ticket, "superseded");
          return int32_t{0};
        }
        const auto result = run();
        if (trace) trace(ticket, result ? "applied" : "native-refused");
        return result;
      };
    }
    const auto finish = [&](int32_t result) {
      if (!result && window && latest_[window] == ticket) latest_[window] = previous;
      return result;
    };
    if (depth_ == 0) {
      Flush();
      return finish(action());
    }
    const auto accepted = PostActivation(std::move(action), post);
    if (trace) trace(ticket, accepted ? "deferred" : "post-refused");
    return finish(accepted ? 1 : 0);
  }

 private:
  struct Deferred { Action action; Post post; };

  bool PostActivation(Action action, const Post& post) {
    return post([this, action = std::move(action), post] {
      // A nested RunUntilIdle must be allowed to empty its queue. Reposting here
      // would keep the enclosing command alive forever, with depth_ still set.
      if (cancelled_) return;
      if (depth_ != 0) parked_.push_back({action, post});
      else action();
    });
  }

  void Leave() {
    if (--depth_ == 0) Flush();
  }

  void Flush() {
    auto work = std::move(parked_);
    parked_.clear();
    for (auto& entry : work) {
      // Keep a refused post for the next safe command boundary, rather than
      // losing activation intent during a temporary task-runner refusal.
      if (!PostActivation(entry.action, entry.post)) {
        parked_.push_back(std::move(entry));
        std::fprintf(stderr, "orbit: deferred native activation scheduling refused\n");
      }
    }
  }

  bool cancelled_ = false;
  int depth_ = 0;
  std::deque<Deferred> parked_;
  uint64_t next_ticket_ = 0;
  std::unordered_map<uint64_t, uint64_t> latest_;
};

}  // namespace orbit_bridge
#endif
