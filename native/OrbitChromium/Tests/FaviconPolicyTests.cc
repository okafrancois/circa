#include "OrbitFaviconPolicy.h"
#include <cassert>
#include <iostream>
#include <memory>
struct FakePNG {
  size_t size = 8;
  bool short_read = false;
  size_t GetSize() { return size; }
  size_t GetData(void* bytes, size_t length, size_t) {
    std::fill_n(static_cast<unsigned char*>(bytes), length, 42);
    return short_read ? length - 1 : length;
  }
};
struct FakeImage {
  size_t width = 16, height = 16;
  int pixels = 16;
  bool representation = true;
  unsigned encodes = 0;
  std::shared_ptr<FakePNG> png = std::make_shared<FakePNG>();
  size_t GetWidth() { return width; }
  size_t GetHeight() { return height; }
  bool GetRepresentationInfo(float, float& scale, int& w, int& h) {
    scale = 1; w = h = pixels; return representation;
  }
  auto GetAsPNG(float scale, bool alpha, int& w, int& h) {
    assert(scale == 1.0f && alpha); ++encodes; w = h = pixels; return png;
  }
};
int main() {
  using orbit_bridge::FaviconReceipt;
  FaviconReceipt state;
  state.Announce({"file:///private/icon", "chrome://favicon", "https://a.test/a.png", "https://a.test/a.png", "https://a.test/b.png"});
  assert(state.candidates.size() == 2 && state.CanStart(0));
  const auto epoch = state.epoch;
  assert(state.Accept(epoch, "https://a.test/a.png"));
  assert(!state.Accept(epoch, "https://b.test/a.png"));
  state.active = true;
  assert(!state.CanStart(0));
  state.Announce({"https://a.test/new.png"});
  assert(!state.Accept(epoch, "https://a.test/a.png"));
  state.Reset(); // Navigation invalidates the receipt, but does not pretend CEF cancelled it.
  assert(state.active && !state.Accept(epoch, "https://a.test/a.png"));
  state.active = false;
  state.Announce({"data:image/png;base64,AA=="});
  assert(state.CanStart(7) && !state.CanStart(8));
  state.requests = 8;
  assert(!state.CanStart(0));
  assert(FaviconReceipt::Bounded(128, 128, 131072));
  assert(!FaviconReceipt::Bounded(129, 1, 1) && !FaviconReceipt::Bounded(1, 1, 131073));
  state.Announce({});
  assert(!state.CanStart(0));
  auto image = std::make_shared<FakeImage>();
  assert(orbit_bridge::ExtractFaviconPNG(image, true, 200).size() == 8);
  assert(orbit_bridge::ExtractFaviconPNG(image, true, 0).size() == 8); // data image
  assert(orbit_bridge::ExtractFaviconPNG(image, false, 200).empty());
  assert(orbit_bridge::ExtractFaviconPNG(image, true, 404).empty());
  image->pixels = 129;
  const auto encodes = image->encodes;
  assert(orbit_bridge::ExtractFaviconPNG(image, true, 200).empty() && image->encodes == encodes);
  image->pixels = 16;
  image->png->size = 131073;
  assert(orbit_bridge::ExtractFaviconPNG(image, true, 200).empty());
  image->png->size = 8;
  image->png->short_read = true;
  assert(orbit_bridge::ExtractFaviconPNG(image, true, 200).empty());
  image->width = 65;
  assert(orbit_bridge::ExtractFaviconPNG(image, true, 200).empty());
  std::cout << "PASS: exact metadata, inline/none, navigation, concurrency and resource limits\n";
}
