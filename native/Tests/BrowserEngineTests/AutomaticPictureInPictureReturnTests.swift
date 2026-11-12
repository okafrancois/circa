import JavaScriptCore
import Testing
@testable import BrowserEngine

@Suite("Automatic Picture in Picture return")
struct AutomaticPictureInPictureReturnTests {
    @Test("Returning closes the automatic session and preserves the playing timeline")
    func automaticReturn() throws {
        let page = try makePage()
        #expect(try run(BrowserAutomaticPiPScript.enter, in: page))
        #expect(try run(BrowserAutomaticPiPScript.returnToSource, in: page))
        #expect(page.evaluateScript("document.pictureInPictureElement === null && exits === 1 && !video.paused && video.currentTime === 9.25")!.toBool())
    }

    @Test("Existing manual PiP is never adopted or closed")
    func manualReturn() throws {
        let page = try makePage()
        page.evaluateScript("document.pictureInPictureElement = video")
        #expect(try !run(BrowserAutomaticPiPScript.enter, in: page))
        #expect(try !run(BrowserAutomaticPiPScript.returnToSource, in: page))
        #expect(page.evaluateScript("document.pictureInPictureElement === video && exits === 0")!.toBool())
    }

    @Test("Manual replacement stays open, including reuse of the same video", arguments: [true, false])
    func manualReplacement(sameVideo: Bool) throws {
        let page = try makePage()
        #expect(try run(BrowserAutomaticPiPScript.enter, in: page))
        page.evaluateScript("leave(); document.pictureInPictureElement = \(sameVideo ? "video" : "{}")")
        #expect(try !run(BrowserAutomaticPiPScript.returnToSource, in: page))
        #expect(page.evaluateScript("document.pictureInPictureElement !== null && exits === 0")!.toBool())
    }

    @Test("Failed entry and already closed sessions do not affect a subsequent manual player", arguments: [true, false])
    func noSession(failedEntry: Bool) throws {
        let page = try makePage()
        if failedEntry { page.evaluateScript("video.requestPictureInPicture = async () => { throw new Error('denied'); }") }
        #expect(try run(BrowserAutomaticPiPScript.enter, in: page) == !failedEntry)
        if !failedEntry { page.evaluateScript("leave()") }
        page.evaluateScript("document.pictureInPictureElement = video")
        #expect(try !run(BrowserAutomaticPiPScript.returnToSource, in: page))
        #expect(page.evaluateScript("exits === 0")!.toBool())
    }

    @Test("A meeting video remains eligible with camera or microphone capture", arguments: ["video", "audio"])
    func meetingVideo(kind: String) throws {
        let page = try makePage()
        page.evaluateScript("video.srcObject = {getTracks:()=>[{kind:'\(kind)',readyState:'live'}]}")
        #expect(try run(BrowserAutomaticPiPScript.enter, in: page))
        #expect(try run(BrowserAutomaticPiPScript.returnToSource, in: page))
    }

    @Test("Automatic video eligibility rejects unavailable, hidden, paused and opted-out players", arguments: [
        "document.pictureInPictureEnabled=false", "document.querySelectorAll=()=>[]",
        "video.muted=true; video.autoplay=true; video.loop=true",
        "video.volume=0", "video.webkitAudioDecodedByteCount=0",
        "navigator.userActivation.hasBeenActive=false", "video.paused=true", "video.ended=true", "video.readyState=1", "video.videoWidth=0",
        "video.disablePictureInPicture=true", "video.checkVisibility=()=>false",
        "video.getBoundingClientRect=()=>({width:640,height:360,bottom:-10,right:700,top:-370,left:60})"
    ])
    func videoEligibility(mutation: String) throws {
        let page = try makePage()
        page.evaluateScript(mutation)
        #expect(try !run(BrowserAutomaticPiPScript.enter, in: page))
    }

    @Test("Live meeting audio is eligible without decoded file audio", arguments: [true, false])
    func liveAudioTrack(enabled: Bool) throws {
        let page = try makePage()
        page.evaluateScript("video.webkitAudioDecodedByteCount=0; video.srcObject={getAudioTracks:()=>[{enabled:\(enabled),readyState:'live'}]}")
        #expect(try run(BrowserAutomaticPiPScript.enter, in: page) == enabled)
    }

    @Test("Eligibility preflight does not start a player or manufacture activation")
    func preflight() throws {
        let page = try makePage()
        #expect(page.evaluateScript(BrowserAutomaticPiPScript.isEligible)!.toBool())
        #expect(page.evaluateScript("document.pictureInPictureElement===null")!.toBool())
        page.evaluateScript("navigator.userActivation.hasBeenActive=false")
        #expect(!page.evaluateScript(BrowserAutomaticPiPScript.isEligible)!.toBool())
    }

    @Test("Ownership loss during pending entry closes the player when entry completes")
    func pendingEntryEnds() throws {
        let page = try makePage()
        page.evaluateScript("let completeEntry; video.requestPictureInPicture=()=>new Promise(resolve=>{completeEntry=()=>{document.pictureInPictureElement=video;resolve()}})")
        page.evaluateScript("globalThis.pendingResult=undefined; (\(BrowserAutomaticPiPScript.enter)).then(value=>globalThis.pendingResult=value)")
        page.evaluateScript(BrowserAutomaticPiPScript.endSession)
        page.evaluateScript("completeEntry()")
        #expect(page.objectForKeyedSubscript("pendingResult")!.toObject() as? Bool == false)
        #expect(page.evaluateScript("document.pictureInPictureElement===null && exits===1")!.toBool())
    }

    private func makePage() throws -> JSContext {
        let page = try #require(JSContext())
        page.evaluateScript(#"""
        let listener;
        let exits = 0;
        const navigator = {userActivation:{hasBeenActive:true}};
        const innerWidth = 1200, innerHeight = 800;
        const video = {
          muted:false, volume:1, webkitAudioDecodedByteCount:1024,
          paused:false, ended:false, readyState:4, videoWidth:640, videoHeight:360,
          disablePictureInPicture:false, currentTime:9.25,
          checkVisibility:() => true,
          getBoundingClientRect:() => ({width:640,height:360,bottom:400,right:700,top:40,left:60}),
          addEventListener:(_, callback) => { listener = callback; },
          removeEventListener:(_, callback) => { if (listener === callback) listener = null; },
          requestPictureInPicture:async () => { document.pictureInPictureElement = video; }
        };
        function leave() {
          document.pictureInPictureElement = null;
          const callback = listener; listener = null; if (callback) callback();
        }
        const document = {
          pictureInPictureEnabled:true, pictureInPictureElement:null,
          querySelectorAll:() => [video],
          exitPictureInPicture:async () => { ++exits; leave(); }
        };
        """#)
        #expect(page.exception == nil)
        return page
    }

    private func run(_ script: String, in page: JSContext) throws -> Bool {
        page.evaluateScript("globalThis.result = undefined; (\(script)).then(value => { globalThis.result = value; })")
        #expect(page.exception == nil)
        return try #require(page.objectForKeyedSubscript("result")?.toObject() as? Bool)
    }
}
