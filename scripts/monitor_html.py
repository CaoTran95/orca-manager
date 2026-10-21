"""Trang HTML tĩnh cho agent monitor (chỉ đọc). Không phụ thuộc thư viện ngoài, không server.

render_html(payload, refresh_seconds) nhận dict từ json_payload() của agent_monitor.py và trả về
một chuỗi HTML hoàn chỉnh. refresh_seconds > 0 làm trang nạp lại <tên>.data.js mỗi N giây (script + ?t=, giữ nguyên bộ lọc và
vị trí cuộn; <meta refresh>/location.reload không đáng tin trong trình duyệt nhúng của Orca); = 0 là ảnh chụp.
"""
import json

_TEMPLATE = r"""<!doctype html>
<html lang="vi"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Agent Monitor</title>
<style>
:root{--bg:#f4f6f8;--surface:#fff;--fg:#17202a;--muted:#5d6b78;--line:#dde3e8;--soft:#eef2f5;
 --working:#17803d;--working-bg:#dff3e5;--waiting:#8a5a00;--waiting-bg:#fff0cf;--done:#2563a8;--done-bg:#e1ecf8;
 --attn:#7a3fb0;--attn-bg:#efe3f8;--unknown:#5d6b78;--unknown-bg:#e8edf1;--accent:#0f766e;
 --font:system-ui,-apple-system,"Segoe UI",sans-serif;--mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace}
@media(prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0f151b;--surface:#17202a;--fg:#e6ebf0;--muted:#92a1af;--line:#2a3642;--soft:#1e2933;
 --working:#5fd68a;--working-bg:#16351f;--waiting:#f0c46a;--waiting-bg:#382d12;--done:#7db4f0;--done-bg:#172c45;
 --attn:#c9a0f0;--attn-bg:#2d1f3d;--unknown:#92a1af;--unknown-bg:#222d37;--accent:#4cc2b6;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#0f151b;--surface:#17202a;--fg:#e6ebf0;--muted:#92a1af;--line:#2a3642;--soft:#1e2933;
 --working:#5fd68a;--working-bg:#16351f;--waiting:#f0c46a;--waiting-bg:#382d12;--done:#7db4f0;--done-bg:#172c45;
 --attn:#c9a0f0;--attn-bg:#2d1f3d;--unknown:#92a1af;--unknown-bg:#222d37;--accent:#4cc2b6;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 var(--font);
 padding:20px max(16px,env(safe-area-inset-left,0px)) 40px max(16px,env(safe-area-inset-right,0px))}
.wrap{max-width:1200px;margin:0 auto;display:flex;flex-direction:column;gap:16px}
header{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:baseline;justify-content:space-between}
h1{font-size:1.3rem;margin:0}
.meta{color:var(--muted);font-size:.82rem}
.meta b{color:var(--fg);font-weight:600}
.stale{background:var(--waiting-bg);color:var(--waiting);padding:6px 12px;border-radius:8px;font-size:.85rem}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:10px}
.stat{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:10px 14px;text-align:left;font:inherit;color:inherit;cursor:pointer}
.stat b{display:block;font:500 1.6rem var(--mono)}
.stat span{font-size:.78rem;color:var(--muted)}
.stat[aria-pressed="true"]{outline:2px solid var(--accent)}
.stat.w b{color:var(--working)}.stat.q b{color:var(--waiting)}.stat.i b{color:var(--attn)}.stat.c b{color:var(--done)}
.bar{display:flex;flex-wrap:wrap;gap:8px}
input[type=search]{flex:1 1 220px;font:inherit;padding:7px 12px;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--fg)}
select{font:inherit;padding:7px 10px;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--fg)}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.feat{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.feat h2{font-size:.95rem;margin:0 0 10px;display:flex;gap:8px;align-items:baseline;flex-wrap:wrap}
.feat h2 small{color:var(--muted);font-weight:400}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,320px),1fr));gap:10px}
.card{border:1px solid var(--line);border-left:4px solid var(--unknown);border-radius:8px;padding:10px 12px;background:var(--soft);min-width:0}
.card.WORKING{border-left-color:var(--working)}.card.WAITING{border-left-color:var(--waiting)}
.card.COMPLETED{border-left-color:var(--done)}.card.INTERRUPTED{border-left-color:var(--attn)}
.top{display:flex;justify-content:space-between;gap:8px;align-items:center;flex-wrap:wrap}
.agent{font-weight:600}
.pill{font-size:.7rem;font-weight:700;letter-spacing:.04em;padding:1px 8px;border-radius:999px;background:var(--unknown-bg);color:var(--unknown)}
.pill.WORKING{background:var(--working-bg);color:var(--working)}.pill.WAITING{background:var(--waiting-bg);color:var(--waiting)}
.pill.COMPLETED{background:var(--done-bg);color:var(--done)}.pill.INTERRUPTED{background:var(--attn-bg);color:var(--attn)}
.repo{color:var(--muted);font-size:.85rem;overflow-wrap:anywhere}
dl{margin:6px 0 0;display:grid;grid-template-columns:auto minmax(0,1fr);gap:1px 10px;font-size:.78rem}
dt{color:var(--muted)}dd{margin:0;font-family:var(--mono);overflow-wrap:anywhere}
.empty{color:var(--muted);text-align:center;padding:30px 0}
details{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:8px 14px;font-size:.82rem;color:var(--muted)}
summary{cursor:pointer;font-weight:600;color:var(--fg)}
details ul{margin:8px 0 0;padding-left:18px}
</style></head><body>
<div class="wrap">
 <header><h1>Agent Monitor</h1><div class="meta" id="meta"></div></header>
 <div class="stale" id="stale" hidden></div>
 <div class="stats" id="stats"></div>
 <div class="bar"><input type="search" id="q" placeholder="Tìm feature, repo, agent, task, session" aria-label="Tìm">
  <select id="grp" aria-label="Nhóm theo"><option value="feature">Nhóm theo feature</option><option value="repository">Nhóm theo repo</option><option value="agent">Nhóm theo agent</option></select></div>
 <div id="groups"></div>
 <details id="warn" hidden><summary id="warnsum"></summary><ul id="warnlist"></ul></details>
 <div class="meta">Chỉ đọc: trang này không tạo hay dừng agent. Dữ liệu từ <code>scripts/agent-monitor.sh --html</code>.</div>
</div>
<script type="application/json" id="data">__DATA__</script>
<script>
(function(){
var D=JSON.parse(document.getElementById("data").textContent), REFRESH=__REFRESH_N__, DATA_JS="__DATA_JS__";
var rows=(D.orchestration||[]).concat(D.manual||[]);
var BUCKETS=[["ATTN","Cần chú ý","i"],["WORKING","Đang làm","w"],["WAITING","Chờ / bị chặn","q"],["COMPLETED","Hoàn thành","c"],["ALL","Tất cả",""]];
var st={f:"ATTN",q:"",g:"feature"};
try{var s=JSON.parse(sessionStorage.getItem("agentMonitor")||"{}");if(s.f)st.f=s.f;if(typeof s.q==="string")st.q=s.q;if(s.g)st.g=s.g;}catch(e){}
function save(){try{sessionStorage.setItem("agentMonitor",JSON.stringify(st));}catch(e){}}
function bucket(r){return (r.bucket||r.agent_status||"UNKNOWN").toString().toUpperCase();}
function inF(r){var b=bucket(r);if(st.f==="ALL")return true;if(st.f==="ATTN")return b!=="COMPLETED";return b===st.f;}
function inQ(r){if(!st.q)return true;var t=[r.feature,r.repository,r.agent,r.task,r.worktree,r.session].join(" ").toLowerCase();return t.indexOf(st.q.toLowerCase())>-1;}
function esc(x){return String(x==null?"-":x).replace(/[&<>"]/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c];});}
function count(f){return rows.filter(function(r){var b=bucket(r);return f==="ALL"?true:f==="ATTN"?b!=="COMPLETED":b===f;}).length;}
function render(){
  document.getElementById("stats").innerHTML=BUCKETS.map(function(b){return '<button class="stat '+b[2]+'" data-f="'+b[0]+'" aria-pressed="'+(st.f===b[0])+'"><b>'+count(b[0])+'</b><span>'+b[1]+'</span></button>';}).join("");
  [].forEach.call(document.querySelectorAll(".stat"),function(el){el.onclick=function(){st.f=el.dataset.f;save();render();};});
  var shown=rows.filter(function(r){return inF(r)&&inQ(r);}),groups={};
  shown.forEach(function(r){var k=r[st.g];if(!k||k==="-")k="(chưa gán)";(groups[k]=groups[k]||[]).push(r);});
  var keys=Object.keys(groups).sort();
  document.getElementById("groups").innerHTML=keys.length?keys.map(function(k){
    var items=groups[k];
    return '<section class="feat"><h2>'+esc(k)+' <small>'+items.length+' session</small></h2><div class="cards">'+items.map(function(r){
      var b=bucket(r);
      return '<article class="card '+esc(b)+'"><div class="top"><span class="agent">'+esc(r.agent)+'</span><span class="pill '+esc(b)+'">'+esc(b)+'</span></div>'+
       '<div class="repo">'+esc(r.repository)+(st.g!=="feature"&&r.feature?' · '+esc(r.feature):'')+'</div><dl>'+
       '<dt>task</dt><dd>'+esc(r.task)+(r.task_status?' ('+esc(r.task_status)+')':'')+'</dd>'+
       '<dt>origin</dt><dd>'+esc(r.origin)+'</dd>'+
       '<dt>worker</dt><dd>'+esc(r.worker_status)+' / '+esc(r.terminal_status)+'</dd>'+
       '<dt>cập nhật</dt><dd>'+esc(r.updated)+'</dd>'+
       '<dt>session</dt><dd>'+esc(r.session)+'</dd></dl></article>';}).join("")+'</div></section>';
  }).join(""):'<div class="empty">Không có session nào khớp bộ lọc.</div>';
  var w=D.warnings||[],box=document.getElementById("warn");box.hidden=!w.length;
  document.getElementById("warnsum").textContent=w.length+" cảnh báo nguồn dữ liệu";
  document.getElementById("warnlist").innerHTML=w.map(function(x){return "<li>"+esc(x)+"</li>";}).join("");
}
document.getElementById("q").value=st.q;document.getElementById("grp").value=st.g;
document.getElementById("q").oninput=function(){st.q=this.value;save();render();};
document.getElementById("grp").onchange=function(){st.g=this.value;save();render();};
function meta(){var sm=D.summary||{},src=D.sources||{};
document.getElementById("meta").innerHTML='Cập nhật <b>'+esc(D.generated_at)+'</b> · '+(sm.total||rows.length)+' session · '+(src.terminals||0)+' terminal · '+(src.runs||0)+' run'+(REFRESH?' · cập nhật trực tiếp mỗi '+REFRESH+'s':' · ảnh chụp một lần');}
function age(){var t=Date.parse(D.generated_at);if(!t||!REFRESH)return;var a=(Date.now()-t)/1000,el=document.getElementById("stale");
  if(a>REFRESH*3+5){el.hidden=false;el.textContent="Dữ liệu đã cũ "+Math.round(a)+"s: script --watch có thể đã dừng.";}else el.hidden=true;}
function apply(nd){D=nd;rows=(D.orchestration||[]).concat(D.manual||[]);meta();render();age();}
meta();render();age();setInterval(age,2000);
if(REFRESH){setInterval(function(){var el=document.createElement("script");el.src=DATA_JS+"?t="+Date.now();
 el.onload=function(){if(window.__AGENT_MONITOR_DATA)apply(window.__AGENT_MONITOR_DATA);el.remove();};el.onerror=function(){el.remove();};document.head.appendChild(el);},REFRESH*1000);}
})();
</script></body></html>
"""


def render_html(payload, refresh_seconds=0, data_js_name="agent-monitor.data.js"):
    refresh = int(refresh_seconds or 0)
    data = json.dumps(payload, ensure_ascii=False).replace("</", "<\\/")
    return (_TEMPLATE.replace("__REFRESH_N__", str(refresh))
            .replace("__DATA_JS__", data_js_name.replace('"', ""))
            .replace("__DATA__", data))


def render_data_js(payload):
    """Dữ liệu cho trang tự cập nhật: trang nạp lại file này (script + ?t=) mỗi N giây, không reload trang."""
    return "window.__AGENT_MONITOR_DATA = " + json.dumps(payload, ensure_ascii=False) + ";\n"
