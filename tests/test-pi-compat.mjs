// Exercise the pinned Pi CLI and the real ops extension without model downloads.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = fileURLToPath(new URL("../", import.meta.url));
const cli = path.join(root, ".tools/pi-compat/node_modules/@earendil-works/pi-coding-agent/dist/cli.js");

for (const modelId of ["spark-x2.5-1.7b", "qwen3.5-0.8b"]) {
  test(`Pi upgrade preserves ${modelId} configuration, ops tools and headless blocking`, { timeout: 45000 }, async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "pi-ops-compat-"));
    const agentDir = path.join(dir, "agent");
    const protectedDir = path.join(dir, "keep");
    await mkdir(agentDir);
    await mkdir(protectedDir);
    await writeFile(path.join(protectedDir, "marker"), "keep");
    const requests = [];
    const errors = [];
    const server = http.createServer(async (req, res) => {
      try {
        assert.equal(req.url, "/v1/chat/completions");
        assert.equal(req.headers.authorization, "Bearer compat-test");
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const body = JSON.parse(Buffer.concat(chunks).toString());
        requests.push(body);
        assert.equal(body.model, modelId);
        assert.equal(body.stream, true);
        if (modelId.startsWith("qwen3.5-")) assert.equal(body.chat_template_kwargs.enable_thinking, false);
        let delta;
        if (requests.length === 1) {
          const names = body.tools.map((tool) => tool.function.name);
          assert.ok(names.includes("ops_service_status"));
          assert.ok(names.includes("ops_disk_usage"));
          assert.ok(names.includes("ops_memory_usage"));
          delta = { tool_calls: [{ index: 0, id: "ops-status", type: "function", function: {
            name: "ops_service_status", arguments: JSON.stringify({ unit: "pi-ops-compat-nonexistent" }),
          } }, { index: 1, id: "ops-memory", type: "function", function: {
            name: "ops_memory_usage", arguments: "{}",
          } }] };
        } else if (requests.length === 2) {
          assert.ok(body.messages.some((message) => message.role === "tool" && JSON.stringify(message.content).includes("exit=")));
          assert.ok(body.messages.some((message) => message.role === "tool" && /Mem:|内存/.test(JSON.stringify(message.content))));
          assert.ok(body.messages.some((message) => message.role === "tool" && /MiB/.test(JSON.stringify(message.content))));
          delta = { tool_calls: [{ index: 0, id: "dangerous-delete", type: "function", function: {
            name: "bash", arguments: JSON.stringify({ command: `rm -rf "${protectedDir}"` }),
          } }] };
        } else {
          assert.equal(requests.length, 3);
          assert.ok(body.messages.some((message) => message.role === "tool" && /拒绝危险操作|未确认危险操作/.test(JSON.stringify(message.content))));
          delta = { content: "compatibility OK" };
        }
        res.writeHead(200, { "Content-Type": "text/event-stream" });
        const chunk = { id: "compat", object: "chat.completion.chunk", created: 1, model: body.model };
        res.write(`data: ${JSON.stringify({ ...chunk, choices: [{ index: 0, delta, finish_reason: null }] })}\n\n`);
        res.write(`data: ${JSON.stringify({ ...chunk, choices: [{ index: 0, delta: {}, finish_reason: delta.tool_calls ? "tool_calls" : "stop" }] })}\n\n`);
        res.end("data: [DONE]\n\n");
      } catch (error) {
        errors.push(error);
        res.writeHead(500);
        res.end(String(error));
      }
    });
    let child;
    try {
      server.listen(0, "127.0.0.1");
      await once(server, "listening");
      await writeFile(path.join(agentDir, "models.json"), JSON.stringify({ providers: {
        "llama-cpp": {
          baseUrl: `http://127.0.0.1:${server.address().port}/v1`,
          api: "openai-completions", apiKey: "compat-test",
          models: [{ id: modelId, contextWindow: modelId.startsWith("qwen3.5-") ? 65536 : 1048576, maxTokens: 4096,
            ...(modelId.startsWith("qwen3.5-") ? { reasoning: false, samplingParams: { chat_template_kwargs: { enable_thinking: false } } } : {}),
          }],
        },
      } }));
      await writeFile(path.join(agentDir, "settings.json"), JSON.stringify({
        defaultProvider: "llama-cpp", defaultModel: modelId,
        enableInstallTelemetry: false, retry: { enabled: false },
      }));
      child = spawn(process.execPath, [cli, "--no-session", "--no-mcp", "--no-extensions",
        "--no-skills", "--no-prompt-templates", "--no-themes", "--thinking", "off",
        "-e", path.join(root, "assets/extensions/ops-tools.ts"), "--mode", "json", "-p", "Run the compatibility check."], {
        cwd: dir, env: { ...process.env, PI_CODING_AGENT_DIR: agentDir }, stdio: ["ignore", "pipe", "pipe"],
      });
      let stdout = "", stderr = "";
      child.stdout.on("data", (data) => { stdout += data; });
      child.stderr.on("data", (data) => { stderr += data; });
      const timer = setTimeout(() => child.kill(), 35000);
      try {
        const [code] = await once(child, "close");
        assert.deepEqual(errors, []);
        assert.equal(code, 0, `requests=${requests.length}\n${stderr}${stdout}`);
        assert.equal(requests.length, 3, stderr + stdout);
        assert.match(stdout, /compatibility OK/);
        const events = stdout.trim().split("\n").map((line) => JSON.parse(line));
        assert.ok(events.some((event) => event.type === "tool_execution_end" && event.toolName === "ops_service_status"
          && !event.isError && event.result?.content?.some((content) => content.type === "text" && content.text.trim())));
        assert.ok(events.some((event) => event.type === "tool_execution_end" && event.toolName === "ops_memory_usage"
          && !event.isError && event.result?.content?.some((content) => content.type === "text" && /Mem:|内存/.test(content.text))));
        assert.doesNotMatch(stderr, /注册失败|Failed to load extension/);
        assert.equal(await readFile(path.join(protectedDir, "marker"), "utf8"), "keep");
      } finally {
        clearTimeout(timer);
      }
    } finally {
      if (child && child.exitCode === null) child.kill();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      await rm(dir, { recursive: true, force: true });
    }
  });
}
