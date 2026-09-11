#!/usr/bin/env node
/**
 * verify-check.js —— deploy-spec 确定性实测层(pi-ops-verify 的组成部分)
 * 解析 deploy-spec YAML 子集 → 逐项只读探测(ss/pgrep/systemctl/curl/fs/net)→ 输出 markdown 实测表。
 * 设计原则:确定性检查交给代码;模型只负责对照期望做判定与汇总,杜绝小模型幻觉证据。
 *
 * 用法: verify-check.js <spec文件>
 * 输出: markdown 实测表(stdout)+ 末行 RESULT 汇总(供脚本解析)
 */
'use strict';
const { spawnSync } = require('child_process');
const fs = require('fs');
const net = require('net');

// ---------- 极简 YAML 子集解析(仅支持本规范:五个 section、列表项 + 缩进键值) ----------
const SECTIONS = ['services', 'dirs', 'files', 'versions', 'connectivity'];
function parseSpec(text) {
  const spec = { services: [], dirs: [], files: [], versions: [], connectivity: [] };
  let section = null, item = null;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/#.*$/, '').replace(/\r$/, '');
    if (!line.trim()) continue;
    const secM = line.match(/^(\w+):\s*$/);
    if (secM && SECTIONS.includes(secM[1])) { section = secM[1]; item = null; continue; }
    if (!section) continue;
    if (/^\s*-\s/.test(line)) {
      item = {};
      spec[section].push(item);
      const kv = line.replace(/^\s*-\s*/, '');
      const m = kv.match(/^(\w+):\s*(.*)$/);
      if (m) item[m[1]] = strip(m[2]);
      else item.path = strip(kv);
      continue;
    }
    const m = line.match(/^\s+(\w+):\s*(.+)$/);
    if (m && item) item[m[1]] = strip(m[2]);
  }
  return spec;
}
const strip = (s) => s.replace(/^['"]|['"]$/g, '').trim();

// ---------- 探测原语(全部只读) ----------
const sh = (cmd) => {
  const r = spawnSync('bash', ['-c', cmd], { encoding: 'utf8', timeout: 8000 });
  return { code: r.status, out: ((r.stdout || '') + (r.stderr || '')).trim() };
};
const checkPort = (port) => {
  const r = sh(`ss -tln | grep -E '[:.]${port}[[:space:]]' || true`);
  return r.out ? { ok: true, ev: r.out.split('\n')[0].slice(0, 120) } : { ok: false, ev: `ss 无 :${port} 监听` };
};
const checkProcess = (pattern) => {
  const r = sh(`pgrep -af ${JSON.stringify(pattern)} | grep -v pgrep | head -3 || true`);
  return r.out ? { ok: true, ev: r.out.split('\n')[0].slice(0, 120) } : { ok: false, ev: `无进程匹配 ${pattern}` };
};
const checkUnit = (unit) => {
  const sys = sh(`systemctl is-active ${JSON.stringify(unit)} 2>&1`);
  if (/^active/.test(sys.out)) return { ok: true, ev: `system(系统级) ${sys.out}` };
  const usr = sh(`systemctl --user is-active ${JSON.stringify(unit)} 2>&1`);
  if (/^active/.test(usr.out)) return { ok: true, ev: `--user ${usr.out}` };
  return { ok: false, ev: `系统级:${sys.out};用户级:${usr.out}` };
};
const checkHttp = (url) => {
  const r = sh(`curl -s -o /dev/null -m 3 -w '%{http_code}' ${JSON.stringify(url)} || echo FAIL`);
  const ok = /^\d{3}$/.test(r.out) && r.out !== '000';
  return { ok, ev: `HTTP ${r.out}` };
};
const checkPath = (p, type) => {
  try {
    const st = fs.statSync(p);
    const ok = type === 'dir' ? st.isDirectory() : st.isFile();
    return { ok, ev: ok ? (type === 'dir' ? '目录存在' : '文件存在') : `存在但不是${type === 'dir' ? '目录' : '文件'}` };
  } catch {
    return { ok: false, ev: '不存在' };
  }
};
const checkNet = (host, port) => new Promise((resolve) => {
  const s = new net.Socket();
  const done = (ok, ev) => { s.destroy(); resolve({ ok, ev }); };
  s.setTimeout(3000, () => done(false, '连接超时(3s)'));
  s.once('error', (e) => done(false, String(e.code || e.message)));
  s.connect(port, host, () => done(true, `TCP ${host}:${port} 可连`));
});

// ---------- 主流程 ----------
async function main() {
  const specFile = process.argv[2];
  if (!specFile || !fs.existsSync(specFile)) {
    console.error('用法: verify-check.js <spec文件>'); process.exit(2);
  }
  const spec = parseSpec(fs.readFileSync(specFile, 'utf8'));
  const rows = [];
  const add = (name, check, r) => rows.push({ name, check, ok: r.ok, ev: r.ev });

  for (const s of spec.services) {
    if (s.port) add(`${s.name} 端口${s.port}`, `端口监听 ${s.port}`, checkPort(s.port));
    if (s.process) add(`${s.name} 进程`, `进程 ${s.process}`, checkProcess(s.process));
    if (s.unit) add(`${s.name} 服务单元`, `systemd ${s.unit}`, checkUnit(s.unit));
    if (s.health) add(`${s.name} 健康检查`, `HTTP ${s.health}`, checkHttp(s.health));
  }
  for (const d of spec.dirs) add(d.path || d.name || String(d), '目录存在', checkPath(d.path || d.name, 'dir'));
  for (const f of spec.files) add(f.path || f.name || String(f), '文件存在', checkPath(f.path || f.name, 'file'));
  for (const v of spec.versions) {
    const r = sh(v.command || '');
    const ok = !v.expect || r.out.includes(v.expect);
    add(v.name || v.command, `命令输出含 "${v.expect}"`, { ok, ev: r.out.split('\n')[0].slice(0, 120) || `退出码 ${r.code}` });
  }
  for (const c of spec.connectivity) add(`连通 ${c.host}:${c.port}`, 'TCP 可连', await checkNet(c.host, Number(c.port)));

  // ---------- 输出 markdown 实测表 ----------
  console.log('## 实测结果(由脚本确定性探测生成,模型不可篡改本节)\n');
  console.log('| 检查项 | 探测方式 | 实测 | 证据 |');
  console.log('|---|---|---|---|');
  for (const r of rows) console.log(`| ${r.name} | ${r.check} | ${r.ok ? '符合' : '不符'} | ${r.ev.replace(/\|/g, '\\|')} |`);
  const pass = rows.filter((r) => r.ok).length;
  const fail = rows.length - pass;
  console.log(`\n实测汇总:符合 ${pass} / 不符 ${fail} / 共 ${rows.length}`);
  console.log(`RESULT rows=${rows.length} passed=${pass} failed=${fail}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
