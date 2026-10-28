#include "OrbitNetworkQoS.h"

#include <atomic>
#include <cstdio>
#include <pthread.h>
#include <sys/qos.h>
#include <unistd.h>

namespace {

std::atomic<bool> network_service{false};
std::atomic<bool> browser_tracking{false};
std::atomic<bool> browser_shutdown{false};
std::atomic<bool> promotion_reported{false};
pthread_mutex_t records_lock = PTHREAD_MUTEX_INITIALIZER;

struct ThreadRecord;
ThreadRecord* records = nullptr;
size_t acquired = 0, released = 0, failures = 0;  // Guarded by records_lock.
size_t release_failures = 0;

struct ThreadRecord {
  pthread_t thread = nullptr;
  pthread_override_t override = nullptr;
  ThreadRecord* next = nullptr;
  ~ThreadRecord() {
    // This runs before pthread teardown. The traversal can never use a freed pthread_t.
    // Apple's override API requires raising requested QoS before ending our own lease.
    // Do it before locking, so a low-QoS exit cannot be descheduled with the registry held.
    if (thread) pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    pthread_mutex_lock(&records_lock);
    if (thread) {
      ThreadRecord** link = &records;
      while (*link && *link != this) link = &(*link)->next;
      if (*link) *link = next;
    }
    if (override) {
      if (pthread_override_qos_class_end_np(override) != 0) ++release_failures;
      ++released;
    }
    pthread_mutex_unlock(&records_lock);
  }
};

bool TrackBrowserThread() {
  thread_local ThreadRecord record;
  pthread_mutex_lock(&records_lock);
  const bool quitting = browser_shutdown.load(std::memory_order_relaxed);
  if (!quitting && browser_tracking.load(std::memory_order_relaxed) && !record.thread) {
    record.thread = pthread_self();
    record.next = records;
    records = &record;
  }
  pthread_mutex_unlock(&records_lock);
  return quitting;
}

int SetNetworkThreadQoS(qos_class_t qos, int relative_priority) {
  // Chromium normally promotes background workers on shutdown, but that happens after
  // ThreadFunc's first QoS assignment. Under contention, that assignment can itself block
  // before WorkerThread::ThreadMain and its shutdown promotion exist. Keep the Network
  // Service at Chromium's kDefault QoS from bootstrap through its persistence drain.
  if (qos == QOS_CLASS_BACKGROUND || qos == QOS_CLASS_UTILITY) {
    const bool network = network_service.load(std::memory_order_relaxed);
    const bool shutting_down = browser_tracking.load(std::memory_order_relaxed) && TrackBrowserThread();
    if (network || shutting_down) {
      qos = QOS_CLASS_USER_INITIATED;
      if (network && !promotion_reported.exchange(true, std::memory_order_relaxed)) {
        constexpr char message[] = "acr: Network Service low QoS promoted\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
      }
    }
  }
  return pthread_set_qos_class_self_np(qos, relative_priority);
}

// dyld interposition is in a private linked image, with no injected library/environment.
// A replacement's reference to the original resolves to the original, not recursively here.
__attribute__((used)) const struct {
  decltype(&SetNetworkThreadQoS) replacement;
  decltype(&pthread_set_qos_class_self_np) original;
} qos_interpose __attribute__((section("__DATA,__interpose"))) = {
    SetNetworkThreadQoS, pthread_set_qos_class_self_np};

}  // namespace

void orbit_bridge::ConfigureNetworkQoS(int argc, char* const argv[]) {
  network_service.store(IsNetworkService(argc, argv), std::memory_order_relaxed);
  if (network_service.load(std::memory_order_relaxed)) {
    constexpr char message[] = "acr: Network Service bootstrap QoS floor active\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
  }
}

void orbit_bridge::ConfigureBrowserQoS() {
  browser_tracking.store(true, std::memory_order_relaxed);
}

orbit_bridge::ShutdownQoSStats orbit_bridge::BeginBrowserShutdownQoS() {
  pthread_mutex_lock(&records_lock);
  browser_shutdown.store(true, std::memory_order_relaxed);
  size_t tracked = 0;
  for (ThreadRecord* record = records; record; record = record->next) {
    ++tracked;
    if (!record->override) {
      record->override = pthread_override_qos_class_start_np(record->thread, QOS_CLASS_USER_INITIATED, 0);
      if (record->override) ++acquired;
      else ++failures;
    }
  }
  const ShutdownQoSStats stats{tracked, acquired - released, acquired, released, failures, release_failures};
  pthread_mutex_unlock(&records_lock);
  std::fprintf(stderr, "acr: browser shutdown QoS tracked=%zu active=%zu acquired=%zu released=%zu failed=%zu release_failed=%zu\n",
               stats.tracked, stats.active, stats.acquired, stats.released, stats.failures, stats.release_failures);
  return stats;
}

orbit_bridge::ShutdownQoSStats orbit_bridge::EndBrowserShutdownQoS() {
  pthread_mutex_lock(&records_lock);
  size_t tracked = 0;
  for (ThreadRecord* record = records; record; record = record->next) {
    ++tracked;
    if (record->override) {
      if (pthread_override_qos_class_end_np(record->override) != 0) ++release_failures;
      ++released;
    }
    record->override = nullptr;
  }
  browser_tracking.store(false, std::memory_order_relaxed);
  browser_shutdown.store(false, std::memory_order_relaxed);
  const ShutdownQoSStats stats{tracked, acquired - released, acquired, released, failures, release_failures};
  pthread_mutex_unlock(&records_lock);
  std::fprintf(stderr, "acr: browser shutdown QoS released=%zu active=%zu failed=%zu release_failed=%zu\n",
               stats.released, stats.active, stats.failures, stats.release_failures);
  return stats;
}
