#include "OrbitContentBlockerFiles.h"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
namespace fs = std::filesystem;
void put(const fs::path& path, const std::string& value) {
  fs::create_directories(path.parent_path());
  std::ofstream(path) << value;
}
int main() {
  char name[] = "/tmp/orbit-blocker-files-XXXXXX";
  assert(mkdtemp(name));
  fs::path work = fs::canonical(name), source = work / "bundle/ContentBlocker";
  for (auto file : orbit_bridge::content_blocker::files) put(source / file, file);
  put(source / "_metadata/generated_indexed_rulesets/_ruleset1", "old generated index");
  fs::create_directory(work / "data");
  fs::create_directory(work / "other");
  auto root = orbit_bridge::AnchoredRoot::Open((work / "data").string());
  auto other = orbit_bridge::AnchoredRoot::Open((work / "other").string());
  chmod(source.c_str(), 0500);
  const auto first = orbit_bridge::StageContentBlocker(*root, source.string());
  assert(!first.empty() && first.starts_with(root->path() + "/"));
  // NSBundle/Foundation returns the /tmp spelling on macOS, unlike POSIX realpath.
  assert(orbit_bridge::StageContentBlocker(*root, std::string(name) + "/bundle/ContentBlocker") == first);
  assert(!fs::exists(fs::path(first) / "_metadata"));
  put(fs::path(first) / "_metadata/generated_indexed_rulesets/_ruleset1", "runtime index");
  assert(orbit_bridge::StageContentBlocker(*root, source.string()) == first);
  assert(fs::exists(fs::path(first) / "_metadata/generated_indexed_rulesets/_ruleset1"));
  assert(orbit_bridge::StageContentBlocker(*other, source.string()) != first);
  // A same-manifest-version resource change still gets a new, complete atomic version.
  put(source / "rulesets/LICENSE.md", "changed license");
  auto second = orbit_bridge::StageContentBlocker(*root, source.string());
  assert(!second.empty() && second != first);
  assert(fs::exists(fs::path(first) / "rulesets/LICENSE.md"));
  assert(!fs::exists(fs::path(second) / "_metadata"));
  for (auto file : orbit_bridge::content_blocker::files) assert(fs::is_regular_file(fs::path(second) / file));
  // Refuse corrupt cached code and symlinks, never overwrite foreign data or use the bundle.
  fs::remove(fs::path(second) / "rulesets/LICENSE.md");
  fs::create_symlink(source / "rulesets/LICENSE.md", fs::path(second) / "rulesets/LICENSE.md");
  assert(orbit_bridge::StageContentBlocker(*root, source.string()).empty());
  fs::remove_all(work / "other/ContentBlocking");
  fs::create_directory_symlink(source, work / "other/ContentBlocking");
  assert(orbit_bridge::StageContentBlocker(*other, source.string()).empty());
  // S-M8: build-time digests. Matching digests stage; a tampered bundled file is refused.
  fs::remove_all(work / "other/ContentBlocking");
  put(source / "rulesets/LICENSE.md", "changed license");
  using orbit_bridge::content_blocker::Sha256Hex;
  const std::string digests[4] = {Sha256Hex("manifest.json"), Sha256Hex("rulesets/easylist.json"),
                                  Sha256Hex("rulesets/easyprivacy.json"), Sha256Hex("changed license")};
  const orbit_bridge::ExpectedDigests expected = {digests[0].c_str(), digests[1].c_str(), digests[2].c_str(),
                                                  digests[3].c_str()};
  assert(Sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  assert(!orbit_bridge::StageContentBlocker(*other, source.string(), expected).empty());
  const std::string wrong = Sha256Hex("tampered");
  const orbit_bridge::ExpectedDigests mismatch = {digests[0].c_str(), digests[1].c_str(), wrong.c_str(),
                                                  digests[3].c_str()};
  assert(orbit_bridge::StageContentBlocker(*other, source.string(), mismatch).empty());
  chmod(source.c_str(), 0700);
  fs::remove(source / "manifest.json");
  assert(orbit_bridge::StageContentBlocker(*root, source.string()).empty());
  fs::remove_all(work);
  std::cout << "Content blocker staging passed\n";
}
