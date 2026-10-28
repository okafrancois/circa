#!/usr/bin/env python3
"""Run preserved witnesses and independent terminal-policy models without CEF or sockets."""
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[4]
out = root / 'native/OrbitChromium/build/review-favicon-r2'
out.mkdir(parents=True, exist_ok=True)

# Only redirect generated scratch; retain the original witnesses and assertions verbatim.
for relative, before, after in [
    ('ReviewFaviconR1/run_callback_review.py', 'build/review-favicon-r1/callback', 'build/review-favicon-r2/original'),
    ('FaviconR2/run_callbacks.py', 'build/favicon-r2/callback', 'build/review-favicon-r2/producer'),
]:
    path = root / 'native/OrbitChromium/Tests' / relative
    source = path.read_text().replace(before, after)
    subprocess.run(['python3', '-c', '__file__ = ' + repr(str(path)) + '\n' + source, 'normal'], check=True)
for mode in ['metadata-disposal', 'obsolete-document', 'removed-profile', 'new-profile-slot',
             'old-runtime-release', 'foreign-thread-destruction', 'waiting-ninth',
             'metadata-runtime-reentry', 'rejected-ui-post']:
    subprocess.run([str(out / 'original/callback-test'), mode], check=True)

extra = r'''
 if(mode=="terminal-completion" || mode=="old-failure-new-runtime") {
   for(uint64_t token=1;token<=2;++token){
     old.hosts.try_emplace(token,Host{});
     old.hosts.at(token).favicon.Announce({"https://synthetic.test/icon.png"});StartFavicon(token);
   }
   auto* rejected=static_cast<FaviconDownload*>(old.hosts.at(1).browser->host.requests.back());
   auto* completed=static_cast<FaviconDownload*>(old.hosts.at(2).browser->host.requests.back());
   State fresh;fresh.extension_lifetime=2;fresh.hosts.emplace(1,Host{});
   if(mode=="old-failure-new-runtime")g_state=&fresh;
   post_allowed=false;
   std::thread worker([&]{rejected->DropForTest();});worker.join();
   assert(FaviconDownload::IsTerminal(1));assert(!FaviconDownload::IsTerminal(2));
   assert(old.favicon_outstanding==2 && old.hosts.at(1).favicon.active && tasks.empty());
   post_allowed=true;
   if(mode=="terminal-completion") {
     unsigned sent=0;old.receive=[&](auto&){++sent;};
     completed->OnDownloadImageFinished("https://synthetic.test/icon.png",200,std::make_shared<CefImage>());
     completed->DropForTest();drain();
     assert(sent==0 && old.favicon_outstanding==1 && !old.hosts.at(2).favicon.active);
     old.hosts.emplace(9,Host{});old.hosts.at(9).favicon.Announce({"https://synthetic.test/icon.png"});
     PumpFavicons();assert(old.hosts.at(9).browser->host.requests.empty());
     assert(FaviconDownload::IsTerminal(1));
   } else {
     fresh.hosts.at(1).favicon.Announce({"https://synthetic.test/icon.png"});StartFavicon(1);
     assert(fresh.favicon_outstanding==1);
     completed->DropForTest();drain();assert(fresh.favicon_outstanding==1);
     fresh.hosts.at(1).favicon.candidates.clear();active(fresh)->DropForTest();drain();
     assert(fresh.favicon_outstanding==0);
   }
   std::cout<<"PASS independent terminal publication/recovery/runtime isolation model\n";return 0;
 }
'''
source = (out / 'original/actual_callback.inc').read_text()
(out / 'actual_callback.inc').write_text(source)
(out / 'actual_metadata.inc').write_text((out / 'original/actual_metadata.inc').read_text())
harness = (root / 'native/OrbitChromium/Tests/ReviewFaviconR1/callback_fake.cc').read_text()
harness = harness.replace(' if(mode=="metadata-runtime-reentry"){', extra + '\n if(mode=="metadata-runtime-reentry"){', 1)
(out / 'terminal.cc').write_text(harness)
subprocess.run(['clang++', '-std=c++20', '-UNDEBUG', '-fsanitize=address,undefined',
    '-fno-omit-frame-pointer', '-g', '-I'+str(out),
    '-I'+str(root / 'native/OrbitChromium/Bridge'), str(out / 'terminal.cc'),
    '-o', str(out / 'terminal')], check=True)
for mode in ['terminal-completion', 'old-failure-new-runtime']:
    subprocess.run([str(out / 'terminal'), mode], check=True)
for name in ['FaviconPolicyTests', 'BridgePolicyTests']:
    subprocess.run(['clang++', '-std=c++20', '-UNDEBUG', '-fsanitize=address,undefined',
        '-fno-omit-frame-pointer', '-I'+str(root / 'native/OrbitChromium/Bridge'),
        str(root / 'native/OrbitChromium/Tests' / (name+'.cc')), '-o', str(out / name)], check=True)
    subprocess.run([str(out / name)], check=True)
for relative in ['ReviewFaviconR1/fixture_review.py', 'FaviconR2/fixture_bounds.py']:
    subprocess.run(['python3', str(root / 'native/OrbitChromium/Tests' / relative)], check=True)
