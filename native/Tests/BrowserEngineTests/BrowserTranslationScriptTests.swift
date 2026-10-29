import JavaScriptCore
import Testing
@testable import BrowserEngine

struct BrowserTranslationScriptTests {
    @Test("Temporarily detached translated text keeps its original", arguments: [true, false])
    func detachedOriginal(scanWhileDetached: Bool) throws {
        let context = try page()
        context.evaluateScript(BrowserTranslationScript.source)
        context.evaluateScript("orbitTranslation.take(); orbitTranslation.apply([{id:'1',text:'Translated text'}]); node.isConnected=false")
        if scanWhileDetached {
            context.evaluateScript("orbitTranslation.take(); node.isConnected=true")
        }
        context.evaluateScript("orbitTranslation.restore(); node.isConnected=true")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("node.data")?.toString() == "Original text")
    }

    @Test("Restoration preserves text changed by the page while detached")
    func concurrentEdit() throws {
        let context = try page()
        context.evaluateScript(BrowserTranslationScript.source)
        context.evaluateScript("orbitTranslation.take(); orbitTranslation.apply([{id:'1',text:'Translated text'}]); node.isConnected=false; node.data='Page update'; orbitTranslation.restore()")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("node.data")?.toString() == "Page update")
    }

    private func page() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        const innerHeight=900, NodeFilter={SHOW_TEXT:4};
        const parent={closest:()=>null, checkVisibility:()=>true,
          getBoundingClientRect:()=>({bottom:100,top:20})};
        const node={isConnected:true,parentElement:parent,data:'Original text'};
        const document={body:{},documentElement:{lang:'de'},createTreeWalker:()=>{
          let visited=false; return {nextNode:()=>{if(visited)return null;visited=true;return node;}};
        }};
        """#)
        return context
    }
}
