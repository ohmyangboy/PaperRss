import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync(new URL('../PaperRss/Sources/App/ArticleReaderView.swift',import.meta.url),'utf8');
const script=source.match(/static let observerScript = WKUserScript\(\s*source: """([\s\S]*?)""",\s*injectionTime:/)[1];
function fixture() {
 const frames=[],messages=[],nodes=[{dataset:{paperRssId:'p0'},getBoundingClientRect:()=>({top:100,bottom:300})}];
 const window={innerHeight:800,paperRssReaderInteractive:false,addEventListener(){},webkit:{messageHandlers:{paperRssReaderScroll:{postMessage(){}},paperRssVisibleParagraphs:{postMessage(p){messages.push(p)}}}}};
 const document={querySelectorAll:()=>nodes,querySelector:q=>({content:q.includes('load-generation')?'7':'article-A'}),addEventListener(){},documentElement:{scrollTop:0},body:{scrollTop:0}};
 const context=vm.createContext({window,document,requestAnimationFrame:f=>frames.push(f),IntersectionObserver:class{observe(){}},Map});
 vm.runInContext(script,context);
 const flush=()=>{while(frames.length)frames.shift()()};
 return {window,messages,flush};
}
test('首屏早于原生就绪时，就绪握手仍能提交当前可见段落',()=>{
 const f=fixture(); f.flush(); assert.equal(f.messages.length,0);
 f.window.paperRssReaderInteractive=true;
 assert.equal(typeof f.window.paperRssRequestVisibleParagraphs,'function');
 f.window.paperRssRequestVisibleParagraphs(7); f.flush();
 assert.equal(f.messages.length,1); assert.deepEqual(Array.from(f.messages[0].paragraphIDs),['p0']);
 assert.equal(f.messages[0].generation,'7'); assert.equal(f.messages[0].documentIdentity,'article-A');
});
test('过期文档握手不会启动当前页面的翻译',()=>{
 const f=fixture();f.flush();f.window.paperRssReaderInteractive=true;
 f.window.paperRssRequestVisibleParagraphs(6);f.flush();assert.equal(f.messages.length,0);
});
test('两个平台都校验段落快照身份并在就绪时请求首屏快照',()=>{
 assert.equal((source.match(/identity == loadedDocumentIdentity, identity == parent.entry.id/g)||[]).length,2);
 assert.equal((source.match(/if \(becameInteractive\) window.paperRssRequestVisibleParagraphs/g)||[]).length,2);
});
