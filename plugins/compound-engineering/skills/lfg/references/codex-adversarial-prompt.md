# Codex Adversarial Review Lane Prompt

This file is loaded by `lfg/SKILL.md` step 3b to compose the prompt sent to `mcp__codex__codex` in parallel with `ce-code-review`.

## Goals

The codex lane is a **second model's** adversarial perspective. It is NOT a duplicate of `ce-adversarial-reviewer` (which runs inside `ce-code-review` on the same model as the orchestrator). Different models catch different blind spots. Pass-through value comes from divergence, not from agreement.

Look for:

- Logic errors, off-by-one bugs, wrong-default branches that the orchestrator may have missed
- Failure modes the orchestrator's review skipped: race conditions, timeouts, partial writes, retry storms
- Hidden coupling — implicit ordering assumptions, shared mutable state, leaky abstractions
- Security: input that flows into shell, SQL, file paths, or external APIs without validation
- Contract drift in exported types, CLI flags, environment variables, or schema migrations
- Documentation that diverges from behavior, especially in skill-prose changes
- Anything the surrounding diff *should* have changed but didn't (sibling files, tests, README)

Do NOT spend tokens on:

- Style nits already enforced by linters
- Restating issues `ce-code-review`'s standard reviewers obviously caught
- Hypothetical concerns not grounded in the actual diff

## Prompt template

Splice in the values marked `<<...>>` before sending. Keep the schema instruction verbatim — the orchestrator parses the response.

```
You are an adversarial code reviewer providing a second-model perspective on a diff that is also being reviewed by another agent. Your job is to surface real, specific defects that another reviewer is likely to miss — not to restate obvious issues.

**Do not modify any files.** This is an analysis-only review. Return findings as JSON; another agent applies fixes.

Plan: <<plan-path>>
Repo root: <<repo-root>>

Diff under review:
<<git-diff-output>>

Review the diff and return ONLY a JSON array (no prose, no markdown fences) matching this schema. Each finding is one object:

{
  "severity": "critical" | "high" | "medium" | "low",
  "file": "<repo-relative path>",
  "line": <integer line number in the new file, or 0 if file-level>,
  "title": "<short imperative title, ~80 chars>",
  "body": "<2-6 sentence explanation of the defect, why it matters, and the failure mode>",
  "autofixable": true | false,
  "suggested_fix": "<concrete diff or replacement text when autofixable=true; empty string otherwise>",
  "confidence": "high" | "medium" | "low",
  "requires_human_judgment": true | false
}

Rules for the schema:
- Set autofixable=true only when the suggested_fix is a clear textual change that does not require choosing between viable alternatives.
- Set confidence=low when you suspect a defect but cannot verify it from the diff alone.
- Set requires_human_judgment=true when the issue depends on product, security, or architectural intent that only the human user can adjudicate (even if you also propose a fix).
- Return [] (empty array) when nothing meaningful surfaces. Do not pad.
- Do not wrap the JSON in markdown fences or commentary. The orchestrator parses the raw response.
```

## Failure modes the orchestrator handles

The orchestrator (`lfg/SKILL.md` step 3b) is responsible for:

- Parsing the response. Unparseable output → single residual entry, pipeline continues.
- Capability check. Codex MCP unavailable → skip lane silently.
- Timeout/error. Codex errors → single residual entry, pipeline continues.
- Autofix application. Serialized after `ce-code-review` autofix to avoid concurrent writes.
- Residual routing. Findings tagged `source: codex-adversarial` flow into the standard residual handoff (step 5).

Do not duplicate any of the above logic in this prompt — keep the prompt focused on the analytical task.
