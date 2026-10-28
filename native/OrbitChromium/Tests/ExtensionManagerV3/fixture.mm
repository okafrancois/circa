#import <AppKit/AppKit.h>
#include "OrbitCefApi.h"
#include "OrbitExtensionPolicy.h"
#include <cassert>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <thread>
@interface FixtureWindow : NSObject
@property BOOL isVisible;
@end
@implementation FixtureWindow
@end
@interface FixtureView : NSObject
@property FixtureWindow* window;
@end
@implementation FixtureView
@end
struct PathString : std::string { using std::string::string; std::string ToString() { return *this; } };
struct Context {
 bool global = false; PathString path = "/synthetic/profile";
 bool IsGlobal() { return global; }
 PathString GetCachePath() { return path; }
 bool IsSame(std::shared_ptr<Context> other) { return other.get() == this; }
};
struct Frame { int loads = 0; void LoadURL(const char* url) { assert(std::string(url) == "chrome://extensions/"); ++loads; } };
struct BrowserHost {
 std::shared_ptr<Context> context = std::make_shared<Context>();
 FixtureView* view;
 auto GetRequestContext() { return context; }
 void* GetWindowHandle() { return (__bridge void*)view; }
};
struct Browser {
 bool valid = true;
 std::shared_ptr<BrowserHost> host = std::make_shared<BrowserHost>();
 std::shared_ptr<Frame> frame = std::make_shared<Frame>();
 bool IsValid() { return valid; }
 int GetIdentifier() { return 7; }
 auto GetHost() { return host; }
 auto GetMainFrame() { return frame; }
};
struct Host {
 uint64_t profile = 2, window = 3, generation = 4;
 bool closing_by_shell = false, close_requested = false;
 std::shared_ptr<Browser> browser = std::make_shared<Browser>();
 orbit_bridge::ExtensionManagerRoute extension_manager_route;
};
struct Event { uint64_t profile_token; };
constexpr int ACR_EVENT_EXTENSIONS_CHANGED = 1;
struct State {
 bool initialized = true, quitting = false;
 uint64_t extension_lifetime = 1;
 const orbit_cef_api_t* orbit;
 std::map<uint64_t, Host> hosts;
 std::map<uint64_t, std::shared_ptr<Context>> profiles;
 std::map<uint64_t, void*> shell_window_handles;
 std::set<uint64_t> ready_profiles{2}, windows{3};
 // Synthetic authenticated-import targets (none here); ExtensionProfilePath refuses them.
 std::set<uint64_t> auth_targets;
 std::map<uint64_t, std::pair<std::string, std::string>> profile_paths{{2,{"/synthetic/profile", "/synthetic/profile"}}};
 Host* Find(uint64_t t) { auto i=hosts.find(t); return i==hosts.end() || !i->second.browser ? nullptr : &i->second; }
 struct Event Event(int, int) { return {}; }
 void Send(struct Event) {}
};
State* g_state;
#define ACR_HOST(token) if (!NSThread.isMainThread || !g_state) return 0; Host* host = g_state->Find(token); if (!host) return 0
extern "C" int32_t ACRExtensionsAvailable();
static orbit_tab_info_t info{sizeof(info), 1, 2, 0, 1, 1, 3};
static std::function<void()> activation;
static bool info_available = true, activate_allowed = true;
static int32_t GetInfo(int, orbit_tab_info_t* out) { *out=info; return info_available; }
static int32_t Activate(int) { info.active=1; if(activation) activation(); return activate_allowed; }
struct BrowseFrame {
 bool main = true;
 PathString url = "https://synthetic.invalid/";
 bool IsMain() { return main; }
 PathString GetURL() { return url; }
};
uint64_t token_ = 1;
bool BeforeBrowseRoute(std::shared_ptr<BrowseFrame> frame, const std::string& url,
                       const std::string& method, bool is_redirect) {
#include "browse.inc"
 return true;
}
#include "actual.inc"
int main() {
 const size_t page = getpagesize();
 char* memory = static_cast<char*>(mmap(nullptr, page*2, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0));
 assert(memory != MAP_FAILED); assert(mprotect(memory+page,page,PROT_NONE)==0);
 // Exactly the genuine v3 prefix; any v4 read touches the inaccessible page.
 constexpr size_t prefix = offsetof(orbit_cef_api_t, extensions_snapshot);
 static_assert(prefix == 120);
 auto* api = reinterpret_cast<orbit_cef_api_t*>(memory+page-prefix);
 memset(api,0,prefix); api->struct_size=prefix; api->version=3;
 api->get_tab_info=GetInfo; api->activate_tab=Activate;
 State state; g_state=&state; state.orbit=api; state.hosts.emplace(1,Host{});
 auto browser=state.hosts.at(1).browser;
 FixtureWindow* window=[FixtureWindow new]; window.isVisible=YES;
 FixtureView* view=[FixtureView new]; view.window=window; browser->host->view=view;
 state.profiles[2]=browser->host->context;
 state.shell_window_handles[3]=(__bridge void*)window;
 assert(!ACRExtensionsAvailable());
 assert(ACROpenExtensionManager(1)==1); // Red on the reviewed baseline.
 assert(browser->frame->loads==1);
 auto frame=std::make_shared<BrowseFrame>();
 frame->main=false;
 assert(BeforeBrowseRoute(frame,"chrome://extensions/","GET",false));
 frame->main=true;
 assert(!BeforeBrowseRoute(frame,"chrome://extensions/","GET",false));
 frame->url="chrome://extensions/";
 assert(!BeforeBrowseRoute(frame,"chrome://extensions/","GET",false));
 frame->url="https://synthetic.invalid/";
 assert(BeforeBrowseRoute(frame,"chrome://extensions/","GET",false));
 for (auto url : {"chrome://settings/", "chrome://extensions/?id=x", "chrome://extensions/#/"}) {
   state.hosts.at(1).extension_manager_route.Arm();
   assert(BeforeBrowseRoute(frame,url,"GET",false));
 }
 state.hosts.at(1).extension_manager_route.Arm();
 assert(BeforeBrowseRoute(frame,"chrome://extensions/","POST",false));
 state.hosts.at(1).extension_manager_route.Arm();
 assert(BeforeBrowseRoute(frame,"chrome://extensions/","GET",true));
 auto refuse = [&] { const int before=browser->frame->loads; assert(ACROpenExtensionManager(1)==0); assert(browser->frame->loads==before); };
 assert(ACRExtensionsSnapshot(2,nullptr,0)==-1);
 assert(ACRExtensionSetEnabled(2,"abcdefghijklmnopabcdefghijklmnop",1)==0);
 assert(ACRExtensionRemove(2,"abcdefghijklmnopabcdefghijklmnop")==0);
 assert(ACRObserveExtensions(2,1)==0);
 assert(ACROpenExtensionManager(99)==0);
 state.initialized=false; refuse(); state.initialized=true;
 state.quitting=true; refuse(); state.quitting=false;
 state.ready_profiles.clear(); refuse(); state.ready_profiles.insert(2);
 state.profile_paths.clear(); refuse(); state.profile_paths[2]={"@global","@global"}; refuse();
 state.profile_paths[2]={"/synthetic/profile","/synthetic/profile"};
 auto context=browser->host->context;
 context->global=true; refuse(); context->global=false;
 context->path=""; refuse(); context->path="/synthetic/profile";
 state.profiles.clear(); refuse(); state.profiles[2]=std::make_shared<Context>(); refuse(); state.profiles[2]=context;
 state.hosts.at(1).closing_by_shell=true; refuse(); state.hosts.at(1).closing_by_shell=false;
 state.hosts.at(1).close_requested=true; refuse(); state.hosts.at(1).close_requested=false;
 browser->valid=false; refuse(); browser->valid=true;
 state.windows.clear(); refuse(); state.windows.insert(3);
 state.shell_window_handles.clear(); refuse(); state.shell_window_handles[3]=(__bridge void*)window;
 view.window=nil; refuse(); view.window=window;
 window.isVisible=NO; refuse(); window.isVisible=YES;
 FixtureWindow* foreign=[FixtureWindow new]; foreign.isVisible=YES;
 view.window=foreign; refuse(); view.window=window;
 info_available=false; refuse(); info_available=true;
 info.hosted=0; refuse(); info.hosted=1;
 info.window_token=4; refuse(); info.window_token=3;
 info.index=-1; refuse(); info.index=0;
 api->get_tab_info=nullptr; refuse(); api->get_tab_info=GetInfo;
 api->activate_tab=nullptr; refuse(); api->activate_tab=Activate;
 api->version=2; refuse(); api->version=3;
 api->struct_size=112; refuse(); api->struct_size=prefix;
 activate_allowed=false; refuse(); activate_allowed=true;
 // Reentrant activation must revoke borrowed host/profile/window/document authority.
 activation=[&]{state.hosts.at(1).generation++;}; refuse();
 activation=[&]{state.hosts.at(1).profile=9;}; refuse(); state.hosts.at(1).profile=2;
 activation=[&]{state.hosts.at(1).window=9;}; refuse(); state.hosts.at(1).window=3;
 activation=[&]{state.windows.clear();}; refuse(); state.windows.insert(3);
 activation=[&]{state.hosts.at(1).close_requested=true;}; refuse(); state.hosts.at(1).close_requested=false;
 activation=[&]{info.active=0;}; refuse(); info.active=1;
 activation=[&]{state.quitting=true;}; refuse(); state.quitting=false;
 activation=[&]{view.window=foreign;state.shell_window_handles[3]=(__bridge void*)foreign;}; refuse();
 view.window=window; state.shell_window_handles[3]=(__bridge void*)window;
 activation=[&]{state.extension_lifetime++;}; refuse();
 State successor; activation=[&]{g_state=&successor;}; refuse(); g_state=&state;
 activation=[&]{state.hosts.clear();}; refuse();
 state.hosts.emplace(1,Host{}); state.hosts.at(1).browser=browser;
 activation=nullptr;
 // Wrong-thread calls fail before touching runtime state or prefix.
 std::thread worker([&]{assert(!ACRExtensionManagementAvailable()); assert(!ACROpenExtensionManager(1));}); worker.join();
 orbit_cef_api_t v4{}; v4.struct_size=sizeof(v4); v4.version=4; v4.get_tab_info=GetInfo; v4.activate_tab=Activate;
 state.orbit=&v4;
 assert(ACRExtensionManagementAvailable()==1 && !ACRExtensionsAvailable());
 assert(ACROpenExtensionManager(1)==1);
 v4.extensions_snapshot=[](const char*,char*,uint32_t){return 0;};
 v4.extension_set_enabled=[](const char*,const char*,int32_t){return 1;};
 v4.extension_remove=[](const char*,const char*){return 1;};
 v4.extensions_observe=[](const char*,void(*)(void*),void*){return 1;};
 v4.extension_action=[](int32_t,const char*,void*,uint64_t,uint64_t,uint64_t,uint64_t){return 1;};
 v4.extension_selection_changed=[](uint64_t,int32_t,uint64_t,uint64_t,uint64_t){return 1;};
 v4.extension_cancel=[](uint64_t){};
 assert(ACRExtensionsAvailable()==1 && ACROpenExtensionManager(1)==1);
 assert(ACRExtensionsSnapshot(2,nullptr,0)==0);
 assert(ACRExtensionSetEnabled(2,"abcdefghijklmnopabcdefghijklmnop",1)==1);
 assert(ACRExtensionRemove(2,"abcdefghijklmnopabcdefghijklmnop")==1);
 assert(ACRObserveExtensions(2,1)==1);
 g_state=nullptr; assert(!ACRExtensionManagementAvailable()); assert(!ACROpenExtensionManager(1)); g_state=&state;
 state.orbit=nullptr; refuse();
 puts("PASS actual v3/v4 manager bodies, absent v4 tail, authority refusals and activation reentry");
 munmap(memory,page*2);
}
