// Live panel: serves index.html and streams runs/<run_id>/events.jsonl over SSE.
// Read-only. Runs inside the orchestrator, or alone: node panel/server.ts [port]

import { createServer, type ServerResponse } from "node:http";
import { closeSync, existsSync, openSync, readdirSync, readFileSync, readSync, statSync, watch } from "node:fs";
import { extname, join, normalize, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".md": "text/plain; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".json": "application/json",
  ".jsonl": "text/plain; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
};

function listRuns(runsRoot: string): string[] {
  if (!existsSync(runsRoot)) return [];
  return readdirSync(runsRoot)
    .filter((d) => existsSync(join(runsRoot, d, "events.jsonl")))
    .sort((a, b) => statSync(join(runsRoot, b)).mtimeMs - statSync(join(runsRoot, a)).mtimeMs);
}

/** Streams the JSONL file: everything already written, then each new line as it lands. */
function streamEvents(file: string, res: ServerResponse): () => void {
  let offset = 0;
  let partial = "";
  const pump = () => {
    if (!existsSync(file)) return;
    const size = statSync(file).size;
    if (size <= offset) return;
    const fd = openSync(file, "r");
    const buf = Buffer.alloc(size - offset);
    readSync(fd, buf, 0, buf.length, offset);
    closeSync(fd);
    offset = size;
    const lines = (partial + buf.toString("utf8")).split("\n");
    partial = lines.pop() ?? "";
    for (const line of lines) if (line.trim()) res.write(`data: ${line}\n\n`);
  };
  pump();
  res.write(`event: replayed\ndata: {}\n\n`);
  // fs.watch can miss appends on some filesystems; a slow poll backs it up.
  const watcher = existsSync(file) ? watch(file, pump) : null;
  const timer = setInterval(pump, 500);
  const keepalive = setInterval(() => res.write(": ka\n\n"), 15000);
  return () => {
    watcher?.close();
    clearInterval(timer);
    clearInterval(keepalive);
  };
}

export function startPanel(runsRoot: string, port: number): Promise<string> {
  const root = resolve(runsRoot);
  const server = createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://x");
    const runs = listRuns(root);
    const run = url.searchParams.get("run") || runs[0];

    if (url.pathname === "/") {
      res.writeHead(200, { "content-type": MIME[".html"] });
      res.end(readFileSync(join(HERE, "index.html")));
      return;
    }
    if (url.pathname === "/api/runs") {
      res.writeHead(200, { "content-type": MIME[".json"] });
      res.end(JSON.stringify(runs));
      return;
    }
    if (url.pathname === "/api/events") {
      if (!run) { res.writeHead(404).end("no runs"); return; }
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
      const stop = streamEvents(join(root, run, "events.jsonl"), res);
      req.on("close", stop);
      return;
    }
    if (url.pathname === "/api/file") {
      // Files inside the run folder only: artifacts, screenshots, raw output.
      const rel = url.searchParams.get("path") ?? "";
      const runDir = join(root, run ?? "");
      const file = normalize(join(runDir, rel));
      if (!run || !file.startsWith(runDir + sep) || !existsSync(file)) { res.writeHead(404).end("not found"); return; }
      res.writeHead(200, { "content-type": MIME[extname(file)] ?? "application/octet-stream" });
      res.end(readFileSync(file));
      return;
    }
    res.writeHead(404).end("not found");
  });
  // A busy port (another panel already serves runs/) must not take the orchestrator down.
  return new Promise((ok, fail) => {
    server.once("error", fail);
    server.listen(port, "127.0.0.1", () => ok(`http://127.0.0.1:${port}`));
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.argv[2] ?? 4317);
  const runsRoot = resolve(HERE, "..", "..", "runs");
  startPanel(runsRoot, port).then((u) => console.log(`panel: ${u}`));
}
