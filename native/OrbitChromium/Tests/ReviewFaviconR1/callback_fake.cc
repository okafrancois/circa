#include "OrbitFaviconPolicy.h"
#include <atomic>
#include <cassert>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <set>
#include <utility>
#include <thread>
#define CEF_REQUIRE_UI_THREAD() assert(ui_thread)
#define IMPLEMENT_REFCOUNTING(Type) public: void DropForTest() { delete this; }
static bool ui_thread = true;
template<class T> using CefRefPtr = std::shared_ptr<T>;
struct CefString : std::string { using std::string::string; CefString(const std::string& s):std::string(s){} std::string ToString() const { return *this; } };
struct PNG { size_t GetSize(){ return 8; } size_t GetData(void* p,size_t n,size_t){ std::fill_n((unsigned char*)p,n,42);return n; } };
struct CefImage { size_t GetWidth(){return 2;} size_t GetHeight(){return 2;} bool GetRepresentationInfo(float,float& s,int& w,int& h){s=1;w=h=2;return true;} auto GetAsPNG(float,bool,int& w,int& h){w=h=2;return std::make_shared<PNG>();} };
struct CefDownloadImageCallback { virtual ~CefDownloadImageCallback()=default; virtual void OnDownloadImageFinished(const CefString&,int,CefRefPtr<CefImage>)=0; };
struct BrowserHost { std::vector<CefDownloadImageCallback*> requests; void DownloadImage(const std::string&,bool favicon,int size,bool bypass,CefDownloadImageCallback* cb){assert(favicon&&size==64&&!bypass);requests.push_back(cb);} };
struct CefBrowser { int id=3; BrowserHost host; int GetIdentifier(){return id;} BrowserHost* GetHost(){return &host;} };
struct Host { uint64_t profile=10,generation=1; bool closing_by_shell=false; orbit_bridge::FaviconReceipt favicon; CefRefPtr<CefBrowser> browser=std::make_shared<CefBrowser>(); };
struct Event { const char* url=nullptr; uint64_t request_id=0; const void* payload=nullptr; size_t payload_size=0; };
const int ACR_EVENT_FAVICON=1;
struct State { uint64_t extension_lifetime=1; unsigned favicon_outstanding=0; bool quitting=false; std::map<uint64_t,Host> hosts; std::set<uint64_t> profiles{10}; std::function<void(const Event&)> receive=[](auto&){}; Host* Find(uint64_t n){auto i=hosts.find(n);return i==hosts.end()?nullptr:&i->second;} ::Event Event(int,uint64_t){return {};} void Send(const ::Event& e){receive(e);} };
State* g_state=nullptr;
std::vector<std::function<void()>> tasks;
bool post_allowed=true;
bool PostUI(std::function<void()> f){ if(!post_allowed)return false;tasks.push_back(std::move(f));return true; }
#include "actual_callback.inc"
struct Client { uint64_t token_=1,profile_=10;
#include "actual_metadata.inc"
};
static FaviconDownload* active(State& s){return static_cast<FaviconDownload*>(s.hosts.at(1).browser->host.requests.back());}
static void drain(){auto pending=std::move(tasks);tasks.clear();for(auto& f:pending)f();}
int main(int argc,char** argv){
 State old;old.hosts.emplace(1,Host{});g_state=&old;
 const std::string mode=argc>1?argv[1]:"normal";
 if(mode=="metadata-runtime-reentry"){
   State fresh;fresh.extension_lifetime=2;fresh.hosts.emplace(1,Host{});
   fresh.hosts.at(1).favicon.Announce({"https://fresh.test/icon.png"});
   old.receive=[&](auto&){g_state=&fresh;};Client client;
   client.OnFaviconURLChange(old.hosts.at(1).browser,{"https://old.test/icon.png"});
   const bool crossed=fresh.favicon_outstanding!=0;
   if(crossed){auto* cb=active(fresh);fresh.hosts.at(1).favicon.candidates.clear();cb->DropForTest();drain();}
   std::cout<<"old metadata stack started new runtime request: "<<crossed<<std::endl;
   return crossed?1:0;
 }
 if(mode=="metadata-disposal"){
   auto browser=old.hosts.at(1).browser;old.receive=[&](auto&){old.hosts.erase(1);};Client client;
   client.OnFaviconURLChange(browser,{"https://old.test/icon.png"});
   assert(old.hosts.empty()&&old.favicon_outstanding==0);std::cout<<"PASS metadata receiver disposal under ASan/UBSan\n";return 0;
 }
 old.hosts.at(1).favicon.Announce({"https://old.test/icon.png"});StartFavicon(1);auto* cb=active(old);
 if(mode=="rejected-ui-post"){
   post_allowed=false;cb->DropForTest();
   std::cout<<"outstanding after UI post rejection: "<<old.favicon_outstanding<<std::endl;
   return old.favicon_outstanding?1:0;
 }
 if(mode=="old-runtime-release"){
   State fresh;fresh.extension_lifetime=2;fresh.favicon_outstanding=1;fresh.hosts.emplace(1,Host{});fresh.hosts.at(1).favicon.active=true;g_state=&fresh;
   cb->OnDownloadImageFinished("https://old.test/icon.png",200,std::make_shared<CefImage>());cb->DropForTest();drain();
   assert(fresh.favicon_outstanding==1&&fresh.hosts.at(1).favicon.active);std::cout<<"PASS old callback preserves new runtime slots\n";return 0;
 }
 if(mode=="new-profile-slot"){
   old.hosts.at(1).profile=20;old.profiles={20};old.hosts.at(1).favicon.active=true;
   ++old.favicon_outstanding;cb->OnDownloadImageFinished("https://old.test/icon.png",200,std::make_shared<CefImage>());cb->DropForTest();drain();
   assert(old.favicon_outstanding==1&&old.hosts.at(1).favicon.active);std::cout<<"PASS old callback preserves new profile active slot\n";return 0;
 }
 if(mode=="waiting-ninth"){
   for(uint64_t token=2;token<=9;++token){old.hosts.emplace(token,Host{});old.hosts.at(token).favicon.Announce({"https://queue.test/icon.png"});StartFavicon(token);}
   assert(old.favicon_outstanding==8&&old.hosts.at(9).browser->host.requests.empty());
   old.hosts.at(1).favicon.candidates.clear();cb->DropForTest();drain();assert(old.favicon_outstanding==8&&old.hosts.at(9).favicon.active);
   for(auto& [token,host]:old.hosts){host.favicon.candidates.clear();if(token!=1)static_cast<FaviconDownload*>(host.browser->host.requests.back())->DropForTest();}
   drain();assert(old.favicon_outstanding==0);std::cout<<"PASS callback release pumps ninth queued browser\n";return 0;
 }
 if(mode=="obsolete-document"){
   auto& host=old.hosts.at(1);++host.generation;host.favicon.Reset();host.favicon.Announce({"https://next.test/icon.png"});
   unsigned sent=0;old.receive=[&](auto&){++sent;};
   cb->OnDownloadImageFinished("https://old.test/icon.png",200,std::make_shared<CefImage>());cb->DropForTest();
   assert(sent==0&&old.favicon_outstanding==1&&host.favicon.active&&host.browser->host.requests.size()==2);
   active(old)->DropForTest();host.favicon.candidates.clear();drain();assert(old.favicon_outstanding==0);
   std::cout<<"PASS obsolete document releases its slot and pumps next document without publication\n";return 0;
 }
 if(mode=="foreign-thread-destruction"){
   old.hosts.at(1).favicon.candidates.clear();
   ui_thread=false;std::thread worker([&]{cb->DropForTest();});worker.join();ui_thread=true;
   assert(old.favicon_outstanding==1);drain();assert(old.favicon_outstanding==0&&!old.hosts.at(1).favicon.active);
   std::cout<<"PASS callback destruction posts state release to simulated UI queue\n";return 0;
 }
 if(mode=="removed-profile"){
   old.profiles.clear();unsigned sent=0;old.receive=[&](auto&){++sent;};
   cb->OnDownloadImageFinished("https://old.test/icon.png",200,std::make_shared<CefImage>());cb->DropForTest();drain();
   assert(sent==0&&old.favicon_outstanding==0&&!old.hosts.at(1).favicon.active);
   std::cout<<"PASS removed profile suppresses publication and releases own slot\n";return 0;
 }
 unsigned sent=0;old.receive=[&](auto&){++sent;old.hosts.erase(1);};
 cb->OnDownloadImageFinished("https://old.test/icon.png",200,std::make_shared<CefImage>());cb->DropForTest();drain();
 assert(sent==1&&old.favicon_outstanding==0);std::cout<<"PASS synchronous disposal from image event under ASan/UBSan\n";
}
