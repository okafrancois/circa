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
        "video.paused=true", "video.ended=true", "video.readyState=1", "video.videoWidth=0",
        "video.disablePictureInPicture=true", "video.checkVisibility=()=>false",
        "video.getBoundingClientRect=()=>({width:640,height:360,bottom:-10,right:700,top:-370,left:60})"
    ])
    func videoEligibility(mutation: String) throws {
        let page = try makePage()
        page.evaluateScript(mutation)
        #expect(try !run(BrowserAutomaticPiPScript.enter, in: page))
    }

    private func makePage() throws -> JSContext {
        let page = try #require(JSContext())
        page.evaluateScript(#"""
        let listener;
        let exits = 0;
        const innerWidth = 1200, innerHeight = 800;
        const video = {
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
