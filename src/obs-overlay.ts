import { createServer, type Server } from "node:http";

export interface ObsState {
  active: boolean;
  mode: string;
  participants: number;
  strengthA: number;
  strengthB: number;
  waveformA: string;
  waveformB: string;
  votes: string[];
  roundRemainingSeconds: number;
  temporaryOperator: string;
  operatorRemainingSeconds: number;
  queueLength: number;
}

export function startObsOverlay(host: string, port: number, getState: () => ObsState): Server {
  const server = createServer((request, response) => {
    if (request.url === "/state") {
      response.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
      response.end(JSON.stringify(getState()));
      return;
    }
    if (request.url === "/" || request.url === "/obs") {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
      response.end(OBS_HTML);
      return;
    }
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not Found");
  });
  server.listen(port, host);
  return server;
}

const OBS_HTML = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{margin:0;background:transparent;color:#fff;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.card{box-sizing:border-box;width:760px;padding:22px 26px;border-radius:22px;background:rgba(13,26,40,.88);box-shadow:0 12px 35px rgba(0,0,0,.35)}
.title{font-size:28px;font-weight:750}.meta{margin-top:8px;color:#b9d4ee;font-size:18px}.channels{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-top:18px}
.channel{padding:16px;border-radius:16px;background:rgba(255,255,255,.08)}.value{font-size:38px;font-weight:800}.wave{font-size:18px;color:#cfe5f8}
.votes{margin-top:16px;font-size:19px;line-height:1.55}.operator{margin-top:12px;color:#ffd783;font-size:18px}
</style></head><body><div class="card"><div class="title">DG-LAB 活动投票</div><div id="meta" class="meta">等待会话</div>
<div class="channels"><div class="channel"><div id="a" class="value">A 0</div><div id="wa" class="wave">波形：-</div></div><div class="channel"><div id="b" class="value">B 0</div><div id="wb" class="wave">波形：-</div></div></div>
<div id="votes" class="votes">当前票数：暂无</div><div id="operator" class="operator"></div></div>
<script>
const set=(id,text)=>document.getElementById(id).textContent=text;
async function refresh(){try{const s=await fetch('/state',{cache:'no-store'}).then(r=>r.json());set('meta',s.active?'参与者 '+s.participants+' · 本轮剩余 '+s.roundRemainingSeconds+'秒':'当前没有活动会话');set('a','A '+s.strengthA);set('b','B '+s.strengthB);set('wa','波形：'+s.waveformA);set('wb','波形：'+s.waveformB);set('votes','当前票数：'+(s.votes.length?s.votes.join('　'):'暂无'));set('operator',s.temporaryOperator?'临时操作员：'+s.temporaryOperator+'（'+s.operatorRemainingSeconds+'秒） · 排队 '+s.queueLength+' 人':'临时操作员：无 · 排队 '+s.queueLength+' 人');}catch{set('meta','状态连接中…')}}
refresh();setInterval(refresh,1000);
</script></body></html>`;
