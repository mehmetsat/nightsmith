// Parses the criteria list out of spec.md and the verdict out of qa_report.md.

export type CriterionClass = "hard" | "soft" | "manual";

export interface Criterion {
  id: string;
  class: CriterionClass;
  text: string;
  verify: string;
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
