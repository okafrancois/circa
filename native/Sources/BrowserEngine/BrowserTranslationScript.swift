package enum BrowserTranslationScript {
    // The isolated world retains node identity; page handlers, markup and form values stay intact.
    // Conditional writes preserve changes made by the page while a batch is in flight.
    package static let source = #"""
    if (!globalThis.orbitTranslation) globalThis.orbitTranslation = (() => {
      const records = new Map(), ids = new WeakMap(); let next = 0;
      const excluded = 'script,style,noscript,textarea,input,select,option,code,pre,[contenteditable]:not([contenteditable="false"]),[translate="no"],.notranslate';
      function eligible(n) {
        const p = n.parentElement;
        if (!n.isConnected || !p || p.closest(excluded) || !p.checkVisibility({checkOpacity:true,checkVisibilityCSS:true})) return false;
        const language = p.closest('[lang]')?.lang;
        if (language && language.split('-')[0] !== document.documentElement.lang.split('-')[0]) return false;
        const rect = p.getBoundingClientRect();
        return rect.bottom >= -200 && rect.top <= innerHeight + 200 && /\p{L}/u.test(n.data) && n.data.length <= 2000;
      }
      return {
        take() {
          for (const [id,r] of records) if (!r.node.deref()) records.delete(id);
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          const batch = []; let size = 0, n;
          while ((n = walker.nextNode())) {
            if (!eligible(n)) continue;
            let id = ids.get(n), r = records.get(id);
            if (r && n.data === r.translated) continue;
            if (batch.length >= 32 || size + n.data.length > 4000) break;
            if (!id) { id = String(++next); ids.set(n,id); }
            r = {node:new WeakRef(n),original:n.data,translated:null}; records.set(id,r);
            batch.push({id,text:n.data}); size += n.data.length;
          }
          return batch;
        },
        apply(batch) {
          for (const item of batch) {
            const r = records.get(item.id);
            const node = r?.node.deref();
            if (node && eligible(node) && node.data === r.original) {
              const leading = r.original.match(/^\s*/u)[0], trailing = r.original.match(/\s*$/u)[0];
              r.translated = leading + item.text.trim() + trailing; node.data = r.translated;
            }
          }
          return true;
        },
        restore() {
          for (const r of records.values()) {
            const node = r.node.deref();
            if (node && r.translated !== null && node.data === r.translated) node.data = r.original;
          }
          records.clear(); return true;
        }
      };
    })()
    """#
}
