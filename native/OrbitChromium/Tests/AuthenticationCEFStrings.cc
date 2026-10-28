// Minimal ASCII-only public CEF string ABI test double. The admitted cookie subset is ASCII.
// Tests link no CEF framework, wrapper, browser, Keychain, server or application runtime.
#include "include/internal/cef_string_types.h"
#include <cstdlib>
#include <cstring>
#include "include/base/cef_logging.h"
namespace cef::logging {
LogMessage::LogMessage(const char* file, int line, LogSeverity severity)
    : severity_(severity), file_(file), line_(line) {}
LogMessage::~LogMessage() { if (severity_ >= LOG_FATAL) abort(); } // No payload logging in tests.
}
extern "C" {
void cef_string_utf8_clear(cef_string_utf8_t* out) { if (out->dtor) out->dtor(out->str); *out = {}; }
void cef_string_utf16_clear(cef_string_utf16_t* out) { if (out->dtor) out->dtor(out->str); *out = {}; }
int cef_string_utf8_set(const char* in, size_t size, cef_string_utf8_t* out, int copy) {
  cef_string_utf8_clear(out); if (!size) return 1;
  if (copy) { out->str = static_cast<char*>(malloc(size+1)); memcpy(out->str, in, size); out->str[size] = 0; out->dtor = [](char* p) { free(p); }; }
  else out->str = const_cast<char*>(in);
  out->length = size; return 1;
}
int cef_string_utf16_set(const char16_t* in, size_t size, cef_string_utf16_t* out, int copy) {
  cef_string_utf16_clear(out); if (!size) return 1;
  if (copy) { out->str = static_cast<char16_t*>(malloc((size+1)*sizeof(char16_t))); memcpy(out->str, in, size*sizeof(char16_t)); out->str[size] = 0; out->dtor = [](char16_t* p) { free(p); }; }
  else out->str = const_cast<char16_t*>(in);
  out->length = size; return 1;
}
int cef_string_utf8_to_utf16(const char* in, size_t size, cef_string_utf16_t* out) {
  cef_string_utf16_clear(out);
  for (size_t n=0; n<size; ++n) if (static_cast<unsigned char>(in[n]) > 127) return 0;
  out->str = static_cast<char16_t*>(calloc(size+1, sizeof(char16_t)));
  out->length = size; out->dtor = [](char16_t* p) { free(p); };
  for (size_t n=0; n<size; ++n) out->str[n] = in[n]; return 1;
}
int cef_string_utf16_to_utf8(const char16_t* in, size_t size, cef_string_utf8_t* out) {
  cef_string_utf8_clear(out);
  for (size_t n=0; n<size; ++n) if (in[n] > 127) return 0;
  out->str = static_cast<char*>(calloc(size+1, 1)); out->length = size; out->dtor = [](char* p) { free(p); };
  for (size_t n=0; n<size; ++n) out->str[n] = static_cast<char>(in[n]); return 1;
}
}
