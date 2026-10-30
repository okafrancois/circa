#ifndef ORBIT_NATIVE_COMMAND_SCOPE_H
#define ORBIT_NATIVE_COMMAND_SCOPE_H

#include <cstdint>
#include <functional>
#include <utility>

namespace orbit_bridge {

// UI-thread command scope: creation callbacks may publish a surface while the
// native tab strip is mutating, but activation must wait for a later loop turn.
class NativeCommandScope {
 public:
  class Command {
   public:
    explicit Command(NativeCommandScope& scope) : scope_(scope) { ++scope_.depth_; }
    ~Command() { --scope_.depth_; }
    Command(const Command&) = delete;
    Command& operator=(const Command&) = delete;
   private:
    NativeCommandScope& scope_;
  };

  using Action = std::function<int32_t()>;
  using Post = std::function<bool(std::function<void()>)>;

  int32_t ActivateOrDefer(Action action, const Post& post) {
    if (depth_ == 0) return action();
    return post([this, action = std::move(action), post] {
      // A nested loop can drain the queue before the enclosing command returns.
      ActivateOrDefer(action, post);
    }) ? 1 : 0;
  }

 private:
  int depth_ = 0;
};

}  // namespace orbit_bridge
#endif
