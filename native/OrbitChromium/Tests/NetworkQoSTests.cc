#include "OrbitNetworkQoS.h"

#include <dlfcn.h>
#include <sys/qos.h>
#include <pthread.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

namespace {

// Requested-QoS getters exclude overrides. Keep negative cases schedulable under the real
// machine load while still checking that the requested class is not rewritten.
struct ExecutionQoS {
  pthread_override_t value = pthread_override_qos_class_start_np(pthread_self(), QOS_CLASS_USER_INITIATED, 0);
  ~ExecutionQoS() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    if (value) pthread_override_qos_class_end_np(value);
  }
};

struct ExitQoSCheck {
  std::atomic<bool>* raised;
  ~ExitQoSCheck() {
    qos_class_t requested = QOS_CLASS_UNSPECIFIED;
    int relative = 0;
    *raised = pthread_get_qos_class_np(pthread_self(), &requested, &relative) == 0 &&
        requested == QOS_CLASS_USER_INITIATED;
  }
};

bool SelectsNetwork(std::initializer_list<const char*> arguments) {
  std::vector<char*> argv;
  for (const char* argument : arguments) argv.push_back(const_cast<char*>(argument));
  return orbit_bridge::IsNetworkService(static_cast<int>(argv.size()), argv.data());
}

}  // namespace

int main(int argc, char* argv[]) {
  if (argc != 3) return 1;
  if (SelectsNetwork({"helper"}) ||
      SelectsNetwork({"helper", "--type=renderer", "--utility-sub-type=network.mojom.NetworkService"}) ||
      SelectsNetwork({"helper", "--type=utility", "--utility-sub-type=audio.mojom.AudioService"}) ||
      SelectsNetwork({"helper", "--utility-sub-type=network.mojom.NetworkService"}) ||
      SelectsNetwork({"helper", "--type=utility", "--utility-sub-type=network.mojom.NetworkServiceSuffix"}) ||
      SelectsNetwork({"helper", "--type=utility", "--utility-sub-type=network.mojom.NetworkService", "--type=renderer"}) ||
      SelectsNetwork({"helper", "--type=renderer", "--", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"}) ||
      SelectsNetwork({"helper", "--type=utility", "--type", "--utility-sub-type=network.mojom.NetworkService"}) ||
      SelectsNetwork({"helper", "--type=utility", "-type=renderer", "--utility-sub-type=network.mojom.NetworkService"}))
    return 2;
  const std::string mode = argv[2];
  char name[] = "helper";
  std::string type = mode == "renderer" ? "--type=renderer" : mode == "gpu" ? "--type=gpu-process" : "--type=utility";
  std::string service = mode == "other" ? "--utility-sub-type=audio.mojom.AudioService"
                                         : "--utility-sub-type=network.mojom.NetworkService";
  char* helper_arguments[] = {name, type.data(), service.data()};
  if (mode != "none" && mode != "browser") orbit_bridge::ConfigureNetworkQoS(3, helper_arguments);
  if (mode == "browser") orbit_bridge::ConfigureBrowserQoS();
  void* fixture = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!fixture) return 4;
  const auto set_and_read = reinterpret_cast<int (*)(qos_class_t, int, qos_class_t*, int*)>(
      dlsym(fixture, "SetAndReadThreadQoS"));
  if (!set_and_read) return 5;
  ExecutionQoS execution;
  if (!execution.value) return 11;
  auto check = [&](qos_class_t requested, qos_class_t expected, int relative = 0) {
    qos_class_t observed = QOS_CLASS_UNSPECIFIED;
    int observed_relative = 0;
    return set_and_read(requested, relative, &observed, &observed_relative) == 0 &&
        observed == expected && observed_relative == relative;
  };
  for (qos_class_t qos : {QOS_CLASS_DEFAULT, QOS_CLASS_USER_INITIATED, QOS_CLASS_USER_INTERACTIVE,
                           QOS_CLASS_UTILITY, QOS_CLASS_BACKGROUND}) {
    const qos_class_t expected = mode == "network" && (qos == QOS_CLASS_UTILITY || qos == QOS_CLASS_BACKGROUND)
        ? QOS_CLASS_USER_INITIATED : qos;
    if (!check(qos, expected, -3)) return 6;
  }
  if (!check(QOS_CLASS_USER_INITIATED, QOS_CLASS_USER_INITIATED)) return 7;
  qos_class_t unused;
  int unused_relative;
  if (set_and_read(QOS_CLASS_UTILITY, 1, &unused, &unused_relative) != EINVAL ||
      set_and_read(QOS_CLASS_UNSPECIFIED, 0, &unused, &unused_relative) != EINVAL) return 8;
  if (mode == "browser") {
    std::atomic<bool> ready{false}, finish{false};
    std::atomic<bool> worker_ok{false}, exit_was_raised{false};
    std::thread worker([&] {
      // TLS order: registry cleanup, check requested QoS, then the test's execution lease.
      // The test lease must not raise requested QoS before the registry destructor does.
      thread_local ExecutionQoS worker_execution;
      thread_local ExitQoSCheck exit_check{&exit_was_raised};
      worker_ok = check(QOS_CLASS_UTILITY, QOS_CLASS_UTILITY);
      ready = true;
      while (!finish) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    });
    while (!ready) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    const auto first = orbit_bridge::BeginBrowserShutdownQoS();
    const auto second = orbit_bridge::BeginBrowserShutdownQoS();
    if (first.active < 2 || first.active != first.tracked || first.failures ||
        second.acquired != first.acquired) std::abort();
    if (!check(QOS_CLASS_BACKGROUND, QOS_CLASS_USER_INITIATED)) return 9;
    finish = true;
    worker.join();  // TLS record removal and override release before End.
    const auto ended = orbit_bridge::EndBrowserShutdownQoS();
    if (ended.active || ended.acquired != ended.released || ended.failures || ended.release_failures) return 12;
    if (!worker_ok || !exit_was_raised || !check(QOS_CLASS_UTILITY, QOS_CLASS_UTILITY)) return 10;
    for (int round = 0; round < 10; ++round) {
      orbit_bridge::ConfigureBrowserQoS();
      std::atomic<int> started{0};
      std::atomic<bool> exit_now{false};
      std::vector<std::thread> workers;
      for (int index = 0; index < 8; ++index) workers.emplace_back([&] {
        ExecutionQoS worker_execution;
        if (!check(QOS_CLASS_UTILITY, QOS_CLASS_UTILITY)) std::abort();
        ++started;
        while (!exit_now) std::this_thread::yield();
      });
      while (started != 8) std::this_thread::yield();
      exit_now = true;  // Race TLS removals against the shutdown traversal.
      orbit_bridge::BeginBrowserShutdownQoS();
      for (auto& item : workers) item.join();
      const auto drained = orbit_bridge::EndBrowserShutdownQoS();
      if (drained.active || drained.acquired != drained.released || drained.failures || drained.release_failures) return 13;
    }
  }
  dlclose(fixture);
  std::printf("NetworkQoSTests: PASS (%s, requested/relative QoS, error forwarding, confinement)\n", mode.c_str());
  return 0;
}
