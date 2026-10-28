#include <pthread.h>
#include <sys/qos.h>

extern "C" int SetAndReadThreadQoS(qos_class_t requested, int relative_priority,
                                   qos_class_t* observed, int* observed_relative) {
  const int result = pthread_set_qos_class_self_np(requested, relative_priority);
  if (result != 0) return result;
  return pthread_get_qos_class_np(pthread_self(), observed, observed_relative);
}
