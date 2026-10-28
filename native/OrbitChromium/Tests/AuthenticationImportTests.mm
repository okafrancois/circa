#include "OrbitAuthenticationCEF.h"
#include "OrbitAuthenticationFiles.h"
#include <cassert>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <thread>
using namespace orbit_auth;
constexpr int64_t kNow = 13437446400000000LL;
Cookie Row(bool domain = false) {
  Cookie row; row.host = domain ? ".auth-fixture.test" : "login.auth-fixture.test";
  row.host_only = !domain; row.name = "ordinary"; row.path = "/scope"; row.value = "invented-only";
  row.same_site = 3; row.priority = 2; row.has_expiry = true; row.expiry = kNow+100000000;
  return row;
}
class Manager final : public CefCookieManager {
 public:
  std::vector<Cookie> cookies;
  CefRefPtr<CefSetCookieCallback> pending_set;
  CefRefPtr<CefCookieVisitor> pending_visitor;
  CefRefPtr<CefCompletionCallback> pending_flush;
  bool false_visit=false, false_set=false, false_flush=false, delayed_set=false, delayed_visit=false, delayed_flush=false;
  bool mismatch=false, ambiguous=false, bad_total=false, early_false=false, malformed_flags=false, count_overflow=false;
  int sets=0, flushes=0, visits=0, expected_priority=1;
  bool VisitAllCookies(CefRefPtr<CefCookieVisitor> visitor) override {
    ++visits;
    if (false_visit) return false;
    if (delayed_visit) { pending_visitor=visitor; return true; }
    Emit(visitor); return true;
  }
  void Emit(CefRefPtr<CefCookieVisitor> visitor) {
    auto copy = cookies;
    if (ambiguous && !copy.empty()) copy.push_back(copy[0]);
    if (count_overflow && !copy.empty()) { auto extra=copy[0]; extra.name="extra"; copy.push_back(extra); }
    for (size_t n=0; n<copy.size(); ++n) {
      auto row=copy[n]; if(mismatch) row.value="different-invented-only";
      CefCookie raw; CefString(&raw.domain)=row.host; CefString(&raw.name)=row.name; CefString(&raw.value)=row.value;
      CefString(&raw.path)=row.path; raw.secure=row.secure; raw.httponly=row.http_only;
      raw.same_site=static_cast<cef_cookie_same_site_t>(row.same_site);
      raw.priority=row.priority==0?CEF_COOKIE_PRIORITY_LOW:row.priority==1?CEF_COOKIE_PRIORITY_MEDIUM:CEF_COOKIE_PRIORITY_HIGH;
      raw.has_expires=row.has_expiry; raw.expires.val=row.expiry;
      raw.creation.val=kNow; raw.last_access.val=kNow;
      if (malformed_flags) raw.secure=2;
      bool remove=true;
      const int total=count_overflow?64:bad_total?65:static_cast<int>(copy.size());
      if (!visitor->Visit(raw, static_cast<int>(n), total, remove)) { assert(!remove); break; }
      assert(!remove);
    }
  }
  bool VisitUrlCookies(const CefString&, bool, CefRefPtr<CefCookieVisitor>) override { assert(false); return false; }
  bool DeleteCookies(const CefString&, const CefString&, CefRefPtr<CefDeleteCookiesCallback>) override { assert(false); return false; }
  bool SetCookie(const CefString& url, const CefCookie& raw, CefRefPtr<CefSetCookieCallback> callback) override {
    ++sets;
    if (false_set) return false;
    assert(int(raw.priority)==expected_priority); // SQL 0/1/2 is CEF -1/0/1, independently asserted.
    Cookie row; assert(ReadCEF(raw,row));
    const auto source=url.ToString(); assert(source.starts_with("https://"));
    if(row.host.empty()) row.host=source.substr(8,source.find('/',8)-8);
    assert(raw.creation.val==0 && raw.last_access.val==0); // Explicitly regenerated, no fabricated times.
    cookies.push_back(row);
    if(delayed_set) { pending_set=callback; return true; }
    callback->OnComplete(true); callback->OnComplete(false); // Duplicate cannot change a terminal.
    return !early_false;
  }
  bool FlushStore(CefRefPtr<CefCompletionCallback> callback) override {
    ++flushes;
    if(false_flush) return false;
    if(delayed_flush) { pending_flush=callback; return true; }
    callback->OnComplete(); callback->OnComplete(); return true;
  }
 private:
  IMPLEMENT_REFCOUNTING(Manager);
};
struct Fixture {
  CefRefPtr<Manager> manager = new Manager;
  std::shared_ptr<int> context=std::make_shared<int>(1);
  std::weak_ptr<int> weak=context;
  bool valid=true, ready_false=false;
  unsigned drains=0;
  std::vector<ACRAuthNotice> notices;
  std::shared_ptr<Operation> operation;
  void Start(std::vector<Cookie> rows={Row()}) {
    manager->expected_priority=rows.empty()?0:rows[0].priority-1;
    auto dispatch=[](std::function<void()> task){task();};
    auto transport=std::make_shared<CEFTransport>(context,[this](CefRefPtr<CefCompletionCallback> callback)->CefRefPtr<CefCookieManager> {
      callback->OnComplete(); callback->OnComplete(); return ready_false ? nullptr : manager;
    }, dispatch);
    context.reset();
    operation=std::make_shared<Operation>(1,2,std::move(rows),transport,[this]{return valid;},[]{return kNow;},
        [this](const ACRAuthNotice& result){notices.push_back(result);},[this]{++drains;});
    operation->Start();
  }
  void Terminal(int code, bool drained=true) {
    assert(!notices.empty() && notices.front().kind==1 && notices.front().status==code);
    assert(std::count_if(notices.begin(),notices.end(),[](auto n){return n.kind==1;})==1);
    assert(operation->drained()==drained);
    assert(drains==unsigned(drained));
  }
};
void Basic() {
  for(bool domain:{false,true}) { Fixture f; auto row=Row(domain); f.Start({row}); f.Terminal(ACR_AUTH_SUBSET_MATCH);
    assert(f.manager->cookies[0].SameProjection(row)); assert(f.manager->sets==1 && f.manager->flushes==1 && f.manager->visits==2);
    assert(f.weak.expired() && f.notices[0].installed==1 && f.notices[0].observed==1); }
  Fixture empty; empty.Start({}); empty.Terminal(ACR_AUTH_SUBSET_MATCH); assert(empty.notices[0].observed==0);
  Fixture initial; initial.manager->cookies.push_back(Row()); initial.Start(); initial.Terminal(ACR_AUTH_NOT_EMPTY);
  assert(initial.manager->sets==0);
  Fixture session; auto transient=Row(); transient.has_expiry=false; transient.expiry=0;
  session.Start({transient}); session.Terminal(ACR_AUTH_SUBSET_MATCH);
  for(int priority=0;priority<3;++priority) {
    Fixture f; auto row=Row(); row.priority=priority; f.Start({row}); f.Terminal(ACR_AUTH_SUBSET_MATCH);
    assert(f.manager->cookies[0].priority==priority);
  }
  Fixture full;
  std::vector<Cookie> maximum;
  for(int n=0;n<64;++n) { auto row=Row(); row.name="row"+std::to_string(n); maximum.push_back(row); }
  full.Start(maximum); full.Terminal(ACR_AUTH_SUBSET_MATCH);
  assert(full.notices[0].installed==64 && full.notices[0].observed==64);
  Fixture overflow; overflow.manager->count_overflow=true; overflow.Start(maximum); overflow.Terminal(ACR_AUTH_INVALID);
  assert(overflow.notices[0].observed==64);
}
ACRAuthCookie Input(const Cookie& row) {
  auto slice=[](const std::string& text) { return ACRAuthBytes{reinterpret_cast<const uint8_t*>(text.data()),uint32_t(text.size())}; };
  ACRAuthCookie input{}; input.struct_size=sizeof(input); input.version=ACR_AUTH_VERSION;
  input.host=slice(row.host); input.name=slice(row.name); input.path=slice(row.path); input.value=slice(row.value);
  input.host_only=row.host_only; input.secure=row.secure; input.http_only=row.http_only;
  input.same_site=row.same_site; input.priority=row.priority; input.has_expiry=row.has_expiry; input.expiry_us=row.expiry;
  input.source_scheme=row.source_scheme; input.source_port=row.source_port; input.source_type=row.source_type;
  input.creation_us=row.creation; input.last_access_us=row.access; input.last_update_us=row.update;
  return input;
}
void Admission() {
  auto row=Row(); auto original=Input(row);
  ACRAuthBatch batch{sizeof(ACRAuthBatch),ACR_AUTH_VERSION,1,2,&original,1,1000};
  auto valid=[&] { std::vector<Cookie> rows; return CopyBatch(&batch,kNow,rows); };
  assert(valid());
  for(int mode=0;mode<10;++mode) {
    auto saved=batch;
    if(mode==0) batch.struct_size--;
    if(mode==1) batch.version++;
    if(mode==2) batch.operation=0;
    if(mode==3) batch.profile=0;
    if(mode==4) batch.row_count=65;
    if(mode==5) batch.rows=nullptr;
    if(mode==6) batch.timeout_ms=0;
    if(mode==7) batch.timeout_ms=30001;
    if(mode==8) original.struct_size--;
    if(mode==9) original.version++;
    assert(!valid()); batch=saved; original=Input(row);
  }
  for(int mode=0;mode<15;++mode) {
    original=Input(row);
    if(mode==0) original.host_only=2;
    if(mode==1) original.secure=2;
    if(mode==2) original.http_only=-1;
    if(mode==3) original.has_expiry=2;
    if(mode==4) original.same_site=4;
    if(mode==5) original.priority=3;
    if(mode==6) original.value.length=4097;
    if(mode==7) original.value.bytes=nullptr;
    if(mode==8) original.partitioned=1;
    if(mode==9) original.source_scheme=1;
    if(mode==10) original.source_port=8443;
    if(mode==11) original.source_type=0;
    if(mode==12) original.last_update_us=-1;
    if(mode==13) original.expiry_us=kNow;
    if(mode==14) original.creation_us=INT64_MAX;
    assert(!valid());
  }
  original=Input(row);
  ACRAuthCookie duplicate[]={original,original}; batch.rows=duplicate; batch.row_count=2; assert(!valid());
  std::vector<Cookie> source;
  for(int n=0;n<64;++n) { auto next=Row(); next.name="row"+std::to_string(n); source.push_back(next); }
  std::vector<ACRAuthCookie> inputs; for(const auto& next:source) inputs.push_back(Input(next));
  batch.rows=inputs.data(); batch.row_count=64; assert(valid());
  batch.row_count=0; batch.rows=nullptr; assert(valid());
  assert(!CopyBatch(nullptr,kNow,source));
}
void Failures() {
  for(int mode=0;mode<8;++mode) {
    Fixture f;
    if(mode==0) f.ready_false=true;
    if(mode==1) f.manager->false_visit=true;
    if(mode==2) f.manager->false_set=true;
    if(mode==3) f.manager->false_flush=true;
    if(mode==4) f.manager->early_false=true;
    if(mode==5) f.manager->mismatch=true;
    if(mode==6) f.manager->ambiguous=true;
    if(mode==7) f.manager->bad_total=true;
    f.Start();
    const int expected=mode==5?ACR_AUTH_MISMATCH:mode==6?ACR_AUTH_AMBIGUOUS:mode==7?ACR_AUTH_INVALID:ACR_AUTH_CEF_REFUSED;
    f.Terminal(expected,mode!=3);
    if(mode==3) { f.operation->BeforeShutdown(); f.operation->ShutdownComplete(); f.Terminal(expected); }
  }
  Fixture gone; gone.valid=false; gone.Start(); gone.Terminal(ACR_AUTH_CONTEXT_GONE,false); assert(gone.manager->sets==0);
  gone.operation->BeforeShutdown(); gone.operation->ShutdownComplete(); gone.Terminal(ACR_AUTH_CONTEXT_GONE);
  Fixture expired; auto row=Row(); row.expiry=kNow; expired.Start({row}); expired.Terminal(ACR_AUTH_INVALID);
}
void DrainAndLifetime() {
  for(int mode=0;mode<4;++mode) {
    Fixture f; f.manager->delayed_set=true; f.Start(); assert(f.notices.empty() && !f.weak.expired());
    if(mode==0) f.operation->Cancel();
    if(mode==1) f.operation->Timeout();
    if(mode==2) f.operation->BeforeShutdown();
    if(mode==3) f.manager->pending_set=nullptr; // Abandoned write is not asserted drained.
    const int expected=mode==0?ACR_AUTH_CANCELLED:mode==1?ACR_AUTH_TIMEOUT:mode==2?ACR_AUTH_SHUTDOWN:ACR_AUTH_ABANDONED;
    f.Terminal(expected,false);
    assert(f.notices[0].pending==2);
    if(mode<2) { assert(!f.weak.expired()); f.manager->pending_set->OnComplete(true); f.manager->pending_set->OnComplete(false); f.manager->pending_set=nullptr; }
    else { f.operation->BeforeShutdown(); f.operation->ShutdownComplete(); }
    f.Terminal(expected); assert(f.notices.size()==2 && f.notices[1].kind==2);
    assert(f.manager->flushes==(mode<2?1:0) && f.weak.expired());
  }
  Fixture visitor; visitor.manager->delayed_visit=true; visitor.Start(); visitor.valid=false;
  visitor.manager->pending_visitor=nullptr; visitor.Terminal(ACR_AUTH_CONTEXT_GONE,false);
  visitor.operation->BeforeShutdown(); visitor.operation->ShutdownComplete(); visitor.Terminal(ACR_AUTH_CONTEXT_GONE);
  Fixture cancelRead; cancelRead.manager->delayed_visit=true; cancelRead.Start(); cancelRead.operation->Cancel();
  cancelRead.Terminal(ACR_AUTH_CANCELLED,false); cancelRead.manager->pending_visitor=nullptr; cancelRead.Terminal(ACR_AUTH_CANCELLED);
  Fixture flush; flush.manager->delayed_flush=true; flush.Start(); flush.operation->Timeout();
  flush.Terminal(ACR_AUTH_TIMEOUT,false); flush.manager->pending_flush->OnComplete(); flush.manager->pending_flush=nullptr;
  flush.Terminal(ACR_AUTH_TIMEOUT);
  Fixture refusedDrain; refusedDrain.manager->delayed_set=true; refusedDrain.manager->false_flush=true; refusedDrain.Start();
  refusedDrain.operation->Cancel(); refusedDrain.manager->pending_set->OnComplete(true); refusedDrain.manager->pending_set=nullptr;
  refusedDrain.Terminal(ACR_AUTH_CANCELLED,false);
  assert(refusedDrain.manager->flushes==1 && !refusedDrain.weak.expired());
  refusedDrain.operation->BeforeShutdown(); refusedDrain.operation->ShutdownComplete(); refusedDrain.Terminal(ACR_AUTH_CANCELLED);
}
void Files() {
  CreationGate gate;
  assert(!gate.Begin(0) && gate.Enter(10));
  assert(gate.Begin(1) && !gate.Begin(2) && !gate.Enter(2));
  assert(gate.Enter(1) && gate.Owns(1) && !gate.Enter(1) && !gate.Enter(2));
  gate.End(); assert(!gate.active() && !gate.Owns(1) && gate.Enter(2));
  char path[]="/tmp/orbit-auth-native-tests-XXXXXX"; assert(mkdtemp(path));
  std::filesystem::path root_path=std::filesystem::canonical(path);
  auto root=orbit_bridge::AnchoredRoot::Open(root_path.string()); assert(root);
  assert(!FreshDirectory::Create(*root,"Auth-test"));
  {std::ofstream marker(root_path/".orbit-auth-synthetic"); marker<<"orbit-auth-synthetic-v1\n";}
  chmod((root_path/".orbit-auth-synthetic").c_str(),0600);
  assert(FreshDirectory::SyntheticRoot(*root));
  auto owned=FreshDirectory::Create(*root,"Auth-test"); assert(owned && owned->Anchored() && owned->Empty());
  assert(!FreshDirectory::Create(*root,"Auth-test")); // Even an empty existing target.
  assert(!FreshDirectory::Create(*root,"Default") && !FreshDirectory::Create(*root,"Auth-../bad"));
  std::filesystem::create_directory(root_path/"foreign");
  std::filesystem::create_symlink(root_path/"foreign",root_path/"Auth-link");
  assert(!FreshDirectory::Create(*root,"Auth-link"));
  std::filesystem::rename(root_path/"Auth-test",root_path/"parked");
  std::filesystem::create_directory(root_path/"Auth-test"); assert(!owned->Anchored());
  chmod((root_path/".orbit-auth-synthetic").c_str(),0644); assert(!FreshDirectory::Create(*root,"Auth-mode"));
  chmod((root_path/".orbit-auth-synthetic").c_str(),0600);
  assert(!link((root_path/".orbit-auth-synthetic").c_str(),(root_path/"marker-linked").c_str()));
  assert(!FreshDirectory::SyntheticRoot(*root)); std::filesystem::remove(root_path/"marker-linked");
  std::filesystem::rename(root_path/".orbit-auth-synthetic",root_path/"marker-real");
  std::filesystem::create_symlink(root_path/"marker-real",root_path/".orbit-auth-synthetic");
  assert(!FreshDirectory::SyntheticRoot(*root));
  owned.reset(); root.reset(); std::filesystem::remove_all(root_path);
}
struct ContextDouble {
  bool global=false;
  int storage=1;
  std::string path;
  bool IsGlobal() const { return global; }
  CefString GetCachePath() const { return path; }
  bool IsSharingWith(const std::shared_ptr<ContextDouble>& other) const { return storage==other->storage; }
};
void ContextAdmission() {
  char pattern[]="/tmp/orbit-auth-context-tests-XXXXXX"; assert(mkdtemp(pattern));
  auto path=std::filesystem::canonical(pattern);
  {std::ofstream marker(path/".orbit-auth-synthetic"); marker<<"orbit-auth-synthetic-v1\n";}
  chmod((path/".orbit-auth-synthetic").c_str(),0600);
  auto root=orbit_bridge::AnchoredRoot::Open(path.string());
  auto directory=FreshDirectory::Create(*root,"Auth-context"); assert(directory);
  auto context=std::make_shared<ContextDouble>(); context->path=directory->path();
  auto global=std::make_shared<ContextDouble>(); global->global=true; global->storage=0;
  std::map<uint64_t,std::shared_ptr<ContextDouble>> contexts{{1,context}};
  std::map<uint64_t,std::shared_ptr<FreshDirectory>> directories{{1,directory}};
  std::set<uint64_t> ready{1};
  auto resolve=[&](uint64_t token=1) { return ResolveContext(token,contexts,directories,ready,global); };
  assert(resolve()==context && !resolve(0) && !resolve(2));
  ready.clear(); assert(!resolve()); ready.insert(1);
  context->global=true; assert(!resolve()); context->global=false;
  context->storage=0; assert(!resolve()); context->storage=1;
  auto alias=std::make_shared<ContextDouble>(); contexts[2]=alias; assert(!resolve()); contexts.erase(2);
  context->path=path.string()+"/Default"; assert(!resolve()); context->path=directory->path();
  contexts.erase(1); assert(!resolve()); contexts[1]=nullptr; assert(!resolve()); contexts[1]=context;
  directories.erase(1); assert(!resolve()); directories[1]=directory;
  chmod(path.c_str(),0755); assert(!resolve()); chmod(path.c_str(),0700);
  std::filesystem::rename(path/"Auth-context",path/"parked");
  std::filesystem::create_directory(path/"Auth-context"); assert(!resolve());
  directory.reset(); root.reset(); directories.clear(); std::filesystem::remove_all(path);
}
void DeferredDispatch() {
  std::vector<std::function<void()>> queue;
  auto dispatch=[&](std::function<void()> task) { queue.push_back(std::move(task)); };
  auto context=std::make_shared<int>(1); std::weak_ptr<int> weak=context;
  CefRefPtr<Manager> manager=new Manager; manager->delayed_visit=true;
  auto transport=std::make_shared<CEFTransport>(context,[manager](CefRefPtr<CefCompletionCallback> callback)->CefRefPtr<CefCookieManager> {
    callback->OnComplete(); return manager;
  },dispatch);
  bool valid=true; unsigned drained=0; std::vector<ACRAuthNotice> notices;
  auto operation=std::make_shared<Operation>(1,2,std::vector<Cookie>{Row()},transport,[&]{return valid;},[]{return kNow;},
      [&](const ACRAuthNotice& notice){notices.push_back(notice);},[&]{++drained;});
  context.reset(); operation->Start(); transport.reset();
  auto pump=[&] {
    unsigned count=0;
    while(!queue.empty()) { assert(++count<16); auto task=std::move(queue.front()); queue.erase(queue.begin()); task(); }
  };
  assert(notices.empty() && queue.size()==1 && !weak.expired());
  pump(); assert(manager->pending_visitor && notices.empty());
  // Only the releasing thread writes this queue; join precedes all UI inspection/pumping.
  std::thread releaser([&]{manager->pending_visitor=nullptr;}); releaser.join();
  assert(queue.size()==1 && notices.empty() && !weak.expired());
  valid=false; pump();
  assert(notices.size()==1 && notices[0].status==ACR_AUTH_CONTEXT_GONE && !operation->drained());
  operation->BeforeShutdown(); assert(weak.expired());
  operation->ShutdownComplete(); assert(drained==1 && notices.size()==2 && notices[1].kind==2);
  assert(manager->sets==0);
}
int main() {
  Fixture malformed; malformed.manager->malformed_flags=true; malformed.Start();
  if (malformed.notices.empty() || malformed.notices[0].status != ACR_AUTH_CEF_REFUSED) {
    fputs("FAIL authentication native: malformed public boolean admitted\n",stderr); return 2;
  }
  Basic(); Admission(); Failures(); DrainAndLifetime(); Files(); ContextAdmission(); DeferredDispatch();
  puts("PASS authentication native: projection, public CEF callbacks, lifetime/drain, fresh ownership (no CEF runtime)");
}
