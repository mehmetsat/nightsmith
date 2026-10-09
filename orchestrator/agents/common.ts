// Runs one agent session on the Agent SDK and streams it into the event log.
// Agents never trigger each other: the orchestrator calls runAgent and reads files.

import { appendFileSync } from "node:fs";
import { join, resolve, sep } from "node:path";
import { query, type CanUseTool } from "@anthropic-ai/claude-agent-sdk";
import { EventLog, SdkNormalizer, firstLine, type AgentName } from "../events.ts";
import { macToolsServer, MAC_TOOL_NAMES } from "./mactools.ts";

export interface AgentRun {
  agent: AgentName;
  round: number;
  model: string;
  cwd: string;
  rolePrompt: string;
  task: string;
  builtinTools: string[];
  macTools: boolean;
  /** Absolute paths (files or directories) the agent may Write/Edit. */
  writable: string[];
  /** Absolute paths inside `writable` that stay off limits (e.g. design files a sprint owns). */
  denied?: string[];
  maxTurns: number;
  maxBudgetUsd?: number;
  appName: string;
  toolsDir: string;
}

export interface AgentOutcome {
  ok: boolean;
  status: string;
  costUsd: number;
  sdkCostUsd: number | null;
  turns: number | null;
  finalText: string;
  /** Set by Harness.agent when the screen was locked during the session (GUI results are void). */
  screenLocked?: boolean;
}

// The subscription's usage windows, as last reported by any agent session (rate_limit_event).
interface UsageWindow { fiveHour: number | null; sevenDay: number | null; resetsAt: number | null; status: string | null }
const windowState: UsageWindow = { fiveHour: null, sevenDay: null, resetsAt: null, status: null };
export function usageWindow(): UsageWindow { return { ...windowState }; }

function trackWindow(log: EventLog, a: AgentRun, msg: Record<string, unknown>) {
  const info = msg.rate_limit_info as { status?: string; resetsAt?: number; unifiedWindows?: Record<string, { utilization?: number; resetsAt?: number }> } | undefined;
  if (!info) return;
  const five = info.unifiedWindows?.five_hour;
  const prev = windowState.fiveHour;
  windowState.status = info.status ?? null;
  windowState.fiveHour = five?.utilization ?? windowState.fiveHour;
  windowState.sevenDay = info.unifiedWindows?.seven_day?.utilization ?? windowState.sevenDay;
  windowState.resetsAt = five?.resetsAt ?? info.resetsAt ?? windowState.resetsAt;
  if (prev == null || Math.abs((windowState.fiveHour ?? 0) - prev) >= 0.02 || info.status !== "allowed") {
    log.emitEvent({ agent: a.agent, round: a.round, type: "rate_limit", summary: `5-hour window ${Math.round((windowState.fiveHour ?? 0) * 100)}%`, payload: { ...windowState } });
  }
}

function writeGuard(writable: string[], cwd: string, denied: string[] = []): CanUseTool {
  const roots = writable.map((p) => resolve(p));
  const blocked = denied.map((p) => resolve(p));
  return async (toolName, input) => {
    if (["Write", "Edit", "MultiEdit", "NotebookEdit"].includes(toolName)) {
      const target = resolve(cwd, String(input.file_path ?? input.notebook_path ?? ""));
      const allowed = roots.some((r) => target === r || target.startsWith(r + sep));
      if (!allowed) {
        return { behavior: "deny", message: `Writing ${target} is not allowed. You may only write: ${roots.join(", ")}` };
      }
      if (blocked.some((b) => target === b || target.startsWith(b + sep))) {
        return { behavior: "deny", message: `${target} is owned by the design track. Call into it from other files; if it needs a change, say so in handoff.md.` };
      }
    }
    // Whole-screen capture would record the user's private work: only single-window (-l) captures.
    if (toolName === "Bash" && /\bscreencapture\b/.test(String(input.command ?? "")) && !/\bscreencapture\b[^|;&]*\s-l\s*\d/.test(String(input.command))) {
      return { behavior: "deny", message: "Whole-screen screencapture is not allowed on the user's Mac. Use the screenshot or record_frames tool (with title for panels)." };
    }
    return { behavior: "allow", updatedInput: input };
  };
}

export async function runAgent(log: EventLog, a: AgentRun): Promise<AgentOutcome> {
  const n = new SdkNormalizer(log, a.agent, a.round, a.model);
  log.emitEvent({ agent: a.agent, round: a.round, type: "agent_start", summary: firstLine(a.task), payload: { model: a.model, task: a.task } });

  const mcpServers = a.macTools
    ? { mac: macToolsServer({ appName: a.appName, toolsDir: a.toolsDir, runDir: log.dir, agent: a.agent, round: a.round }) }
    : undefined;

  let status = "ok";
  let finalText = "";
  let sdkCost: number | null = null;
  let turns: number | null = null;
  let modelUsage: Record<string, unknown> | null = null;
  let finalUsage: { input_tokens?: number; output_tokens?: number; cache_read_input_tokens?: number; cache_creation_input_tokens?: number } | null = null;
  // Every SDK message, verbatim, for after-the-fact analysis of usage and behaviour.
  const sdkLog = join(log.rawDir, `r${a.round}_${a.agent}_sdk.jsonl`);
  try {
    const stream = query({
      prompt: a.task,
      options: {
        model: a.model,
        cwd: a.cwd,
        systemPrompt: { type: "preset", preset: "claude_code", append: a.rolePrompt },
        tools: a.builtinTools,
        allowedTools: a.macTools ? MAC_TOOL_NAMES : [],
        mcpServers,
        // Only the MCP servers passed here. Without this, the user's claude.ai connectors
        // (Notion, Slack, Figma, ...) add ~140k tokens of tool definitions to every request.
        strictMcpConfig: true,
        canUseTool: writeGuard(a.writable, a.cwd, a.denied),
        permissionMode: "default",
        // Isolation: no user/project settings, CLAUDE.md or plugins leak into the agents.
        settingSources: [],
        maxTurns: a.maxTurns,
        maxBudgetUsd: a.maxBudgetUsd,
        persistSession: false,
        env: { ...process.env, ENABLE_CLAUDEAI_MCP_SERVERS: "false", AXCLI_APP: a.appName, AXCLI: `${a.toolsDir}/axcli/.build/release/axcli` },
        stderr: (d) => log.writeRaw(a.agent, a.round, "sdk_stderr", d),
      },
    });
    for await (const msg of stream) {
      appendFileSync(sdkLog, JSON.stringify(msg) + "\n");
      n.handle(msg as { type: string });
      if (msg.type === "rate_limit_event") trackWindow(log, a, msg as unknown as Record<string, unknown>);
      if (msg.type === "result") {
        const r = msg as unknown as {
          subtype: string; result?: string; total_cost_usd: number; num_turns: number; is_error?: boolean;
          modelUsage?: Record<string, unknown>;
          usage?: { input_tokens?: number; output_tokens?: number; cache_read_input_tokens?: number; cache_creation_input_tokens?: number };
        };
        finalUsage = r.usage ?? null;
        modelUsage = r.modelUsage ?? null;
        status = r.subtype === "success" && !r.is_error ? "ok" : r.subtype;
        finalText = r.result ?? "";
        sdkCost = r.total_cost_usd;
        turns = r.num_turns;
      }
    }
  } catch (err) {
    status = "error";
    const message = err instanceof Error ? err.message : String(err);
    log.emitEvent({ agent: a.agent, round: a.round, type: "error", summary: firstLine(message), payload: { message } });
  }

  // Streamed frames carry stale usage (output tokens especially). The result message has the
  // real totals, so agent_end carries the difference: per-round sums then equal the SDK's figures.
  const realIn = finalUsage ? (finalUsage.input_tokens ?? 0) + (finalUsage.cache_read_input_tokens ?? 0) + (finalUsage.cache_creation_input_tokens ?? 0) : null;
  const correction = {
    input_tokens: realIn == null ? 0 : realIn - n.totals.input_tokens,
    output_tokens: finalUsage ? (finalUsage.output_tokens ?? 0) - n.totals.output_tokens : 0,
    cost_usd: sdkCost == null ? 0 : sdkCost - n.totals.cost_usd,
  };
  log.emitEvent({
    agent: a.agent, round: a.round, type: "agent_end", ...correction, summary: `${status}${finalText ? ": " + firstLine(finalText, 120) : ""}`,
    payload: {
      status, sdk_cost_usd: sdkCost, num_turns: turns, model_usage: modelUsage, context_tokens: n.lastContextTokens,
      input_tokens: n.totals.input_tokens, output_tokens: n.totals.output_tokens, cost_usd_estimate: n.totals.cost_usd,
    },
  });
  return { ok: status === "ok", status, costUsd: sdkCost ?? n.totals.cost_usd, sdkCostUsd: sdkCost, turns, finalText };
}
