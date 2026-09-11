/**
 * pi-ops-agent 运维扩展:
 *  1) 危险操作审批门 —— 拦截 bash/powershell 的危险语义命令,并对写类工具(write/edit)
 *     写敏感路径(~/.ssh、systemd 用户单元、/etc、shell 配置)设门。
 *     注意:这是 best-effort 纵深防御层,不是沙箱;生产环境请叠加低权限用户/容器隔离。
 *  2) 只读运维工具 —— ops_service_status / ops_disk_usage
 *
 * 安装位置:~/.pi/agent/extensions/pi-ops-tools.ts(pi 经 jiti 加载,免编译)
 * 返回值契约:pi 0.85.x 的自定义工具 execute 必须返回
 *   { content: [{type:"text",text}], details } —— 裸字符串会被静默丢弃(模型收到空结果)!
 */

const { execFileSync } = require("child_process");

/** 工具结果包装(契约形状) */
const ok = (text: string, details: any = {}) => ({ content: [{ type: "text", text }], details });

/** 归一化:去引号/转义符、压空白(对抗 `"rm" -rf`、`r'm'` 类混淆) */
const norm = (s: string) => String(s).replace(/["'\\]/g, "").replace(/\s+/g, " ");

function run(file: string, args: string[]) {
  return execFileSync(file, args, {
    encoding: "utf8",
    timeout: 15000,
    maxBuffer: 4 * 1024 * 1024,
  }).toString();
}

/**
 * bash 危险语义判定(best-effort;经对抗评审,覆盖分离旗标/长旗标/盘设备写入/
 * 下载即执行变形/systemctl 非读动词等绕过形态)
 */
function isDangerousCommand(raw: string): boolean {
  const c = norm(raw);

  // --- rm:分离/合并/长旗标的 r+f 共现 ---
  if (/\brm\b/.test(c)) {
    const toks = c.split(" ");
    const i = toks.indexOf("rm");
    if (i >= 0) {
      let r = false, f = false;
      for (const t of toks.slice(i + 1)) {
        if (t === ";" || t === "&&" || t === "||") break;
        if (/^-[a-zA-Z]*r/.test(t) || t === "-recursive" || t === "--recursive") r = true;
        if (/^-[a-zA-Z]*f/.test(t) || t === "-force" || t === "--force") f = true;
      }
      if (r && f) return true;
    }
  }

  // --- 关机/重启 ---
  if (/\b(shutdown|reboot|poweroff|halt|telinit)\b/i.test(c) || /\binit\s+[06]\b/.test(c)) return true;

  // --- 块设备/磁盘覆写(设备名 × 写语义) ---
  const dev = /\/dev\/(sd|nvme|vd|mmcblk|xvd)/.test(c) || /\/dev\/(sd|nvme|vd|mmcblk|xvd)[a-z0-9]*\b/.test(c);
  const wr =
    /\bdd\b[^;|]*of=/.test(c) || /\bdd\b[^;|]*if=/.test(c) ||
    /\b(tee|shred|blkdiscard|wipefs|mkfs[\w.]*|mke2fs)\b/.test(c) ||
    />\s*\/dev\//.test(c) ||
    /find\b[^;|]*-delete/.test(c) ||
    /\bcp\b[^;|]*\/dev\/(sd|nvme|vd|mmcblk|xvd)/.test(c);
  if (dev && wr) return true;
  if (/\bdd\b[^;|]*(if|of)=\/dev\//.test(c)) return true;

  // --- 写系统配置 / 持久化入口 ---
  const writeVerb =
    />\s*/.test(c) || /\btee\b/.test(c) ||
    /\bsed\b[^;|]*\s(-[a-zA-Z]*i\b|--in-place)/.test(c) ||
    /\b(chattr|install)\b/.test(c);
  if (/\/etc\//.test(c) && writeVerb) return true;
  if (/(\.ssh\/|\.config\/systemd\/|\.bashrc|\.profile|crontab)/i.test(c) &&
      (writeVerb || /\bcp\b/.test(c))) return true;

  // --- 下载即执行(管道/进程替换/两步落地变形) ---
  if (/(curl|wget)\b[^;|&]*\|/.test(c) &&
      /\|\s*(sudo\s+)?(\/?(usr\/)?bin\/)?(ba|z|da)?sh\b|\|\s*(sudo\s+)?(source|eval|python\d?|node|perl)\b/.test(c))
    return true;
  if (/\b(ba|z|da)?sh\b\s*<\(/.test(c)) return true;
  if (/(curl|wget)\b[^;|]*\s(-o|--output)\s+\S+.*&&\s*(ba|z|da)?sh\b/.test(c)) return true;

  // --- systemctl:只放行读动词,其余(status/show/cat/list/is-* 之外)一律确认 ---
  if (/\bsystemctl\b/.test(c)) {
    const READ = /^(--user\s+)?(status|show|cat|list|is-|help)/;
    for (const seg of c.split(/[;|&]{1,2}/)) {
      const m = seg.trim().match(/systemctl\s+(.*)$/);
      if (m && !READ.test(m[1].trim())) return true;
    }
  }

  // --- 杀关键进程 / 防火墙写 / 权限放开 ---
  if (/\b(pkill|killall)\b[^;|]*(sshd?|network|systemd|docker)/i.test(c)) return true;
  if (/\bnft\b[^;|]*(flush|add|delete|insert)/.test(c)) return true;
  if (/\biptables\b[^;|]*\s(-A|-D|-F|-X|-Z|-t\s+nat)/.test(c)) return true;
  if (/\bchmod\b[^;|]*(777|a\+w)/.test(c) && /(-R|--recursive)/.test(c)) return true;

  return false;
}

/** 写类工具的敏感路径(防"不经 bash 直写持久化入口"的结构性绕过) */
const SENSITIVE_WRITE_PATH =
  /(\.ssh\/|\.config\/systemd\/|\.bashrc|\.profile|\/etc\/|crontab)/i;

export default function (pi: any) {
  // ---------- 1. 审批门 ----------
  pi.on("tool_call", async (event: any, ctx: any) => {
    let needConfirm = false;
    let what = "";

    if (event.toolName === "bash" || event.toolName === "powershell") {
      const cmd = (event.input && (event.input.command || event.input.script)) || "";
      if (isDangerousCommand(cmd)) {
        needConfirm = true;
        what = String(cmd);
      }
    } else if (event.toolName === "write" || event.toolName === "edit") {
      const path = (event.input && (event.input.path || event.input.file_path || event.input.file)) || "";
      if (SENSITIVE_WRITE_PATH.test(String(path))) {
        needConfirm = true;
        what = `写入敏感路径:${path}`;
      }
    }
    if (!needConfirm) return;

    let okFlag = false;
    try {
      // pi 0.85.x 签名:confirm(title, message, opts?) —— 没有"默认值"参数
      okFlag = await ctx.ui.confirm("⚠ pi-ops-agent:危险操作确认", what);
    } catch {
      okFlag = false; // headless(-p)模式下无交互 → 默认拒绝(安全优先)
    }
    if (!okFlag) return { block: true, reason: `用户未确认危险操作: ${what}` };
  });

  // ---------- 2. 只读工具(schema 用裸 JSON Schema,pi 0.85.x 原生支持) ----------
  try {
    pi.registerTool({
      name: "ops_service_status",
      label: "服务状态",
      description: "查看 systemd 服务状态(只读)。输入单元名,如 sshd、docker、nginx。服务未运行时返回 inactive 状态而非报错。",
      parameters: {
        type: "object",
        properties: { unit: { type: "string", description: "systemd 单元名" } },
        required: ["unit"],
      },
      async execute(_toolCallId: string, params: any) {
        try {
          const text = run("systemctl", ["status", "--no-pager", "-l", "-n", "30", "--", params.unit]);
          return ok(text);
        } catch (e: any) {
          // systemctl 退出码:active=0/inactive|dead=3/不存在=4 —— 非零退出本身就是答案的一部分
          return ok(`exit=${e.status}\n${e.stdout || e.stderr || e.message}`);
        }
      },
    });
  } catch (e) {
    console.error("[pi-ops] ops_service_status 注册失败:", e);
  }

  try {
    pi.registerTool({
      name: "ops_disk_usage",
      label: "磁盘用量",
      description: "查看磁盘分区用量(只读),等价 df -h。",
      parameters: { type: "object", properties: {}, required: [] },
      async execute() {
        return ok(run("df", ["-h"]));
      },
    });
  } catch (e) {
    console.error("[pi-ops] ops_disk_usage 注册失败:", e);
  }
}
