import AppKit
import BrowserCore
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Local synthetic media exercises eligibility and native window lifetime together.
    func automaticPiPRegression(_ owner: OrbitWindowController, _ engine: ChromiumBrowserEngine) async {
        func evaluate(_ source: String, _ tab: ChromiumSurface) async -> String? {
            try? await engine.conformanceProbe?.evaluateScript(source, in: tab)
        }
        func floatingWindows() -> [NSWindow] {
            NSApp.windows.filter { $0.isVisible && $0.level == .floating && !$0.styleMask.contains(.titled) }
        }
        func stage(_ name: String) {
            let value = "\(name) main=\(owner.window?.windowNumber ?? 0) pip=\(floatingWindows().map(\.windowNumber)) pid=\(ProcessInfo.processInfo.processIdentifier)\n"
            try? Data(value.utf8).write(to: runRoot.appendingPathComponent("pip-stage.txt"))
        }
        owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        owner.submitAddress(fixture.appendingPathComponent("fixture").absoluteString)
        guard let tab = await committed(owner, fixture.appendingPathComponent("fixture")),
              let tabID = owner.session.organization?.selectedTab?.id else { check("pip.fixture", false); return }
        _ = await evaluate(#"""
        document.body.innerHTML='';
        globalThis.canvas=document.createElement('canvas'); canvas.width=640; canvas.height=360;
        globalThis.video=document.createElement('video'); video.muted=true; video.autoplay=true;
        video.loop=true; video.playsInline=true; video.style='width:100vw;height:100vh;object-fit:cover';
        video.srcObject=canvas.captureStream(30); document.body.append(video);
        globalThis.paint=setInterval(()=>{let c=canvas.getContext('2d');c.fillStyle='teal';c.fillRect(0,0,640,360);c.fillStyle='white';c.font='40px sans-serif';c.fillText('Synthetic background '+Math.floor(performance.now()/100),30,180)},30);
        video.play(); 'ready'
        """#, tab)
        try? await Task.sleep(for: .seconds(1))
        stage("muted-playing")
        try? await Task.sleep(for: .seconds(2))
        owner.openTab(url: fixture.appendingPathComponent("fixture?background=1"))
        await owner.session.waitForPendingCommands()
        try? await Task.sleep(for: .seconds(2))
        check("pip.muted-no-player", await evaluate("String(document.pictureInPictureElement===null)", tab) == "true" && floatingWindows().isEmpty)
        stage("muted-no-pip")
        try? await Task.sleep(for: .seconds(3))
        owner.session.selectTab(tabID); await owner.session.waitForPendingCommands()
        _ = await evaluate(#"""
        globalThis.audio=new AudioContext(); globalThis.osc=audio.createOscillator();
        globalThis.gain=audio.createGain();gain.gain.value=0.015;
        globalThis.output=audio.createMediaStreamDestination();osc.connect(gain);gain.connect(output);
        video.srcObject.addTrack(output.stream.getAudioTracks()[0]);video.muted=false;video.volume=1;
        osc.start();audio.resume();video.play(); 'audible'
        """#, tab)
        try? await Task.sleep(for: .seconds(1))
        stage("audible-playing")
        try? await Task.sleep(for: .seconds(2))
        owner.openTab(url: fixture.appendingPathComponent("fixture?audible=1"))
        await owner.session.waitForPendingCommands()
        let opened = await until(5) { !floatingWindows().isEmpty }
        let inPiP = await evaluate("String(document.pictureInPictureElement===video)", tab) == "true"
        check("pip.audible-open", opened && inPiP)
        stage("audible-pip")
        try? await Task.sleep(for: .seconds(4))
        _ = await owner.session.closeOwnedSurface(tab).value
        let closed = await until(5) { floatingWindows().isEmpty }
        check("pip.close-removes-window", closed && tab.isDisposed)
        stage("closed-no-pip")
        try? await Task.sleep(for: .seconds(3))
    }
}
