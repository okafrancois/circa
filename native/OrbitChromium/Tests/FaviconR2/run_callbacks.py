#!/usr/bin/env python3
"""Additional exact-body tests. Independent R1 harness and assertions stay unchanged.

Emits only fixed synthetic favicon receipts to an ignored replay file. No socket,
CEF, window, personal source, callback payload logging or external image loading.
"""
import importlib.util
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[4]
out = root / 'native/OrbitChromium/build/favicon-r2/callback'
out.mkdir(parents=True, exist_ok=True)
source = (root / 'native/OrbitChromium/Bridge/OrbitChromiumBridge.mm').read_text()
(out / 'actual_callback.inc').write_text(source[source.index('void StartFavicon(uint64_t token);'):source.index('class Client final')])
start = source.index('  void OnFaviconURLChange(')
(out / 'actual_metadata.inc').write_text(source[start:source.index('  // ABI 9: element fullscreen.', start)].replace(' override', ''))
spec = importlib.util.spec_from_file_location('fixture', root / 'tools/favicon-fixture/server.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
png = fixture.png(220, 25, 40, 2, 2)
array = ','.join(str(byte) for byte in png)
harness = (root / 'native/OrbitChromium/Tests/ReviewFaviconR1/callback_fake.cc').read_text()
a = harness.index('struct PNG {')
b = harness.index('struct CefImage', a)
harness = harness[:a] + f'''struct PNG {{
 std::vector<unsigned char> bytes {{{array}}};
 size_t GetSize(){{return bytes.size();}}
 size_t GetData(void* p,size_t n,size_t){{std::copy_n(bytes.data(),n,(unsigned char*)p);return n;}}
}};
''' + harness[b:]
extra = r'''
 if(mode=="fallback" || mode=="exhausted"){
   std::ofstream replay(argv[2]);
   unsigned announcements=0,images=0;uint64_t previous=0;
   old.receive=[&](auto& e){
     if(!e.payload){assert(e.request_id>previous);previous=e.request_id;++announcements;}
     else {assert(e.request_id==previous);++images;}
     replay<<e.request_id<<" "<<(e.url?e.url:"-")<<" ";
     if(e.payload){for(size_t n=0;n<e.payload_size;++n){auto byte=((const unsigned char*)e.payload)[n];replay<<"0123456789abcdef"[byte>>4]<<"0123456789abcdef"[byte&15];}}
     else replay<<"-";
     replay<<"\n";
   };
   Client client;client.OnFaviconURLChange(old.hosts.at(1).browser,{"https://fixture.example.test/a.png","https://fixture.example.test/b.png"});
   auto* first=active(old);first->OnDownloadImageFinished("https://fixture.example.test/a.png",404,nullptr);first->DropForTest();
   assert(announcements==2 && previous==2 && old.favicon_outstanding==1);
   auto* second=active(old);assert(second!=first);
   second->OnDownloadImageFinished("https://fixture.example.test/b.png",mode=="fallback"?200:404,mode=="fallback"?std::make_shared<CefImage>():nullptr);
   second->DropForTest();drain();
   assert(old.favicon_outstanding==0 && !old.hosts.at(1).favicon.active);
   assert(mode=="fallback"?(images==1 && announcements==2):(images==0 && announcements==3));
   std::cout<<"PASS explicit fallback candidate announcements and terminal receipt\n";return 0;
 }
 if(mode=="foreign-rejected-post"){
   old.hosts.at(1).favicon.Announce({"https://fixture.example.test/a.png"});StartFavicon(1);auto* callback=active(old);
   post_allowed=false;ui_thread=false;std::thread worker([&]{callback->DropForTest();});worker.join();ui_thread=true;
   assert(old.favicon_outstanding==1 && old.hosts.at(1).favicon.active && tasks.empty());
   assert(FaviconDownload::IsTerminal(old.extension_lifetime));
   old.hosts.emplace(9,Host{});old.hosts.at(9).favicon.Announce({"https://fixture.example.test/b.png"});StartFavicon(9);
   assert(old.hosts.at(9).browser->host.requests.empty());
   State fresh;fresh.extension_lifetime=2;fresh.hosts.emplace(1,Host{});g_state=&fresh;
   fresh.hosts.at(1).favicon.Announce({"https://fixture.example.test/b.png"});StartFavicon(1);assert(fresh.favicon_outstanding==1);
   fresh.hosts.at(1).favicon.candidates.clear();active(fresh)->DropForTest();assert(fresh.favicon_outstanding==0);
   std::cout<<"PASS failed foreign UI post terminals only its receipt lifetime\n";return 0;
 }
 if(mode=="foreign-release-new-runtime"){
   old.hosts.at(1).favicon.Announce({"https://fixture.example.test/a.png"});StartFavicon(1);auto* callback=active(old);
   ui_thread=false;std::thread worker([&]{callback->DropForTest();});worker.join();ui_thread=true;
   State fresh;fresh.extension_lifetime=2;fresh.hosts.emplace(1,Host{});g_state=&fresh;
   fresh.hosts.at(1).favicon.Announce({"https://fixture.example.test/b.png"});drain();
   assert(fresh.favicon_outstanding==0 && fresh.hosts.at(1).browser->host.requests.empty());
   std::cout<<"PASS deferred old release cannot pump a new runtime\n";return 0;
 }
 if(mode=="fallback-runtime-reentry"){
   old.hosts.at(1).favicon.Announce({"https://fixture.example.test/a.png","https://fixture.example.test/b.png"});StartFavicon(1);auto* callback=active(old);
   State fresh;fresh.extension_lifetime=2;fresh.hosts.emplace(1,Host{});fresh.hosts.at(1).favicon.Announce({"https://fixture.example.test/b.png"});
   old.receive=[&](auto&){g_state=&fresh;};
   callback->OnDownloadImageFinished("https://fixture.example.test/a.png",404,nullptr);callback->DropForTest();drain();
   assert(fresh.favicon_outstanding==0 && fresh.hosts.at(1).browser->host.requests.empty());
   std::cout<<"PASS failed candidate announcement cannot pump replacement runtime\n";return 0;
 }
'''
harness = harness.replace('#include <atomic>', '#include <atomic>\n#include <fstream>')
harness = harness.replace(' if(mode=="metadata-runtime-reentry"){', extra + '\n if(mode=="metadata-runtime-reentry"){', 1)
(out / 'harness.cc').write_text(harness)
exe = out / 'callbacks'
subprocess.run(['clang++', '-std=c++20', '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-g',
    '-I'+str(out), '-I'+str(root / 'native/OrbitChromium/Bridge'), str(out / 'harness.cc'), '-o', str(exe)], check=True)
for mode in ['fallback', 'exhausted', 'foreign-rejected-post', 'foreign-release-new-runtime', 'fallback-runtime-reentry']:
    subprocess.run([str(exe), mode, str(out / (mode+'.receipts'))], check=True)
