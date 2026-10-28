// Temporary macOS Network Service workaround; see DBG-CH3 for scope and removal criteria.
#ifndef ORBIT_NETWORK_QOS_H
#define ORBIT_NETWORK_QOS_H

#include <string_view>
#include <cstddef>

namespace orbit_bridge {

inline bool IsNetworkService(int argc, char* const argv[]) {
  bool utility = false;
  bool network = false;
  bool saw_type = false;
  bool saw_service = false;
  for (int index = 1; index < argc; ++index) {
    const std::string_view argument(argv[index]);
    if (argument == "--") break;
    if (argument == "--type" || argument == "--utility-sub-type" ||
        argument == "-type" || argument == "-utility-sub-type" ||
        argument.starts_with("-type=") || argument.starts_with("-utility-sub-type=")) return false;
    if (argument.starts_with("--type=")) {
      if (saw_type) return false;
      saw_type = true;
      utility = argument == "--type=utility";
    }
    if (argument.starts_with("--utility-sub-type=")) {
      if (saw_service) return false;
      saw_service = true;
      network = argument == "--utility-sub-type=network.mojom.NetworkService";
    }
  }
  return utility && network;
}

// Call before loading CEF, before it creates any threads. No PID enumeration or task ports.
void ConfigureNetworkQoS(int argc, char* const argv[]);

// Browser threads retain their ordinary QoS until quitting. Records live in thread-local
// storage; their destructor and the shutdown traversal share a lock, keeping pthread handles
// alive until each native override is installed/removed. No task_for_pid or PID discovery.
void ConfigureBrowserQoS();
struct ShutdownQoSStats {
  size_t tracked, active, acquired, released, failures, release_failures;
};
ShutdownQoSStats BeginBrowserShutdownQoS();
ShutdownQoSStats EndBrowserShutdownQoS();

}  // namespace orbit_bridge

#endif  // ORBIT_NETWORK_QOS_H
