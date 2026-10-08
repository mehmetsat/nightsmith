// Parses the criteria list out of spec.md and the verdict out of qa_report.md.

export type CriterionClass = "hard" | "soft" | "manual";

export interface Criterion {
  id: string;
  class: CriterionClass;
  text: string;
  verify: string;
  // v2: where a criterion added by a replan came from
  origin?: string;
  novelty?: "new" | "obvious";
  added_in?: number;
}

export interface QaResult {
  id: string;
  status: "PASS" | "FAIL" | "MANUAL";
  evidence?: string;
  repro?: string;
}

export interface QaVerdict {
  results: QaResult[];
  scores: Record<string, number>;
  spec_issue: boolean;
  spec_issue_reason?: string;
}

export interface RoundScore {
  hard_pass: number;
  hard_total: number;
  hard_fail_ids: string[];
  missing_ids: string[];
  soft_pass: number;
  soft_total: number;
  manual: number;
  scores: Record<string, number>;
  spec_issue: boolean;
  spec_issue_reason?: string;
}

function jsonBlocks(md: string): string[] {
  return [...md.matchAll(/```(?:json)?\s*\n([\s\S]*?)\n```/g)].map((m) => m[1]);
}

export function parseCriteria(specMd: string): Criterion[] {
  const idx = specMd.search(/^##\s+Criteria\b/m);
  if (idx < 0) throw new Error("spec.md has no '## Criteria' section");
  const section = specMd.slice(idx);
  const block = jsonBlocks(section)[0] ?? section.slice(section.indexOf("["), section.lastIndexOf("]") + 1);
  const arr = JSON.parse(block) as Criterion[];
  if (!Array.isArray(arr) || !arr.length) throw new Error("Criteria JSON is empty or not an array");
  for (const c of arr) {
    if (!c.id || !["hard", "soft", "manual"].includes(c.class)) throw new Error(`bad criterion: ${JSON.stringify(c).slice(0, 200)}`);
  }
  return arr;
}

export function parseQaReport(md: string): QaVerdict {
  for (const block of jsonBlocks(md)) {
    try {
      const v = JSON.parse(block);
      // Accept the requested single object, or [results] followed by a separate {scores} block.
      if (Array.isArray(v)) {
        const rest = jsonBlocks(md).map((b) => { try { return JSON.parse(b); } catch { return null; } }).find((x) => x && !Array.isArray(x) && x.scores);
        return { results: v, scores: rest?.scores ?? {}, spec_issue: rest?.spec_issue === true, spec_issue_reason: rest?.spec_issue_reason };
      }
      if (Array.isArray(v.results)) {
        return { results: v.results, scores: v.scores ?? {}, spec_issue: v.spec_issue === true, spec_issue_reason: v.spec_issue_reason };
      }
    } catch {
      /* try the next block */
    }
  }
  throw new Error("qa_report.md has no parseable JSON block with results");
}

export function scoreRound(criteria: Criterion[], v: QaVerdict): RoundScore {
  const byId = new Map(v.results.map((r) => [r.id, r]));
  const hard = criteria.filter((c) => c.class === "hard");
  const soft = criteria.filter((c) => c.class === "soft");
  const hardPass = hard.filter((c) => byId.get(c.id)?.status === "PASS");
  return {
    hard_pass: hardPass.length,
    hard_total: hard.length,
    // A hard criterion QA skipped counts as failed.
    hard_fail_ids: hard.filter((c) => byId.get(c.id)?.status !== "PASS").map((c) => c.id),
    missing_ids: criteria.filter((c) => !byId.has(c.id)).map((c) => c.id),
    soft_pass: soft.filter((c) => byId.get(c.id)?.status === "PASS").length,
    soft_total: soft.length,
    manual: criteria.filter((c) => c.class === "manual").length,
    scores: v.scores,
    spec_issue: v.spec_issue,
    spec_issue_reason: v.spec_issue_reason,
  };
}

// ---------------------------------------------------------------------------
// v2: the spec may grow, never shrink. The loop enforces that, not the replanner.

export interface SpecGuard {
  criteria: Criterion[];
  added: Criterion[];
  restored: string[];
  dropped: string[];
}

/**
 * Compares the replanned criteria with the previous ones. Existing criteria come back exactly
 * as they were (a replanner cannot weaken the floor); at most `max` new ones are kept.
 */
export function guardSpec(previous: Criterion[], next: Criterion[], max: number, round: number, vetoedOrigins: Set<string>): SpecGuard {
  const prevById = new Map(previous.map((c) => [c.id, c]));
  const restored: string[] = [];
  const dropped: string[] = [];
  const added: Criterion[] = [];
  for (const c of next) {
    if (prevById.has(c.id)) {
      const p = prevById.get(c.id)!;
      if (p.text !== c.text || p.verify !== c.verify || p.class !== c.class) restored.push(c.id);
      continue;
    }
    const valid = c.id && ["hard", "soft", "manual"].includes(c.class) && c.text && c.verify;
    if (!valid || (c.origin && vetoedOrigins.has(c.origin)) || added.length >= max) { dropped.push(c.id ?? "?"); continue; }
    added.push({ ...c, added_in: round, novelty: c.novelty === "obvious" ? "obvious" : "new" });
  }
  for (const p of previous) if (!next.some((c) => c.id === p.id)) restored.push(p.id);
  return { criteria: [...previous, ...added], added, restored, dropped };
}

/** Replaces the Criteria JSON block in spec.md, keeping the prose above it. */
export function writeCriteria(specMd: string, criteria: Criterion[]): string {
  const idx = specMd.search(/^##\s+Criteria\b/m);
  const head = idx < 0 ? specMd.trimEnd() + "\n\n" : specMd.slice(0, idx);
  const section = idx < 0 ? "" : specMd.slice(idx);
  const intro = section.split("```")[0].replace(/^##\s+Criteria\b.*\n/m, "").trim();
  return `${head}## Criteria\n\n${intro ? intro + "\n\n" : ""}\`\`\`json\n${JSON.stringify(criteria, null, 2)}\n\`\`\`\n`;
}
