---
title: "feat: Add delegation and configurable MCP/agent providers to lfg skill"
type: feat
status: active
date: 2026-05-06
---

# feat: Add delegation and configurable MCP/agent providers to lfg skill

## Summary

Extend the `lfg` skill to (a) accept a delegation flag (`delegate:codex` with codex CLI primary and codex MCP fallback) that propagates through the pipeline by routing the work step to `ce-work-beta`, (b) accept a list of additional MCP/agent provider names (e.g. `mcp:perplexity,codex`) that are auto-invoked at appropriate pipeline phases when capable enough for the task, and (c) add a parallel codex-MCP adversarial review pass alongside the existing `ce-code-review` invocation, with autofix and a residual list for human-judgment items.

---

## Problem Frame

`lfg` is the autopilot pipeline (`ce-plan` → `ce-work` → `ce-code-review` → tests → PR). Today it always uses `ce-work` (no codex delegation), runs only the standard Claude-side review (no parallel adversarial pass via codex MCP), and has no surface for the user's installed MCP providers (perplexity, codex, etc.). The user has explicit guidance in global CLAUDE.md to prefer `ce-work-beta delegate:codex` and to fire a parallel codex adversarial lane during reviews — none of which `lfg` currently honors. This plan brings `lfg` into alignment with that two-lane review pattern and makes provider selection lightweight and string-driven.

---

## Requirements

- R1. `lfg` accepts argument tokens `delegate:codex` and `delegate:local` that override config, mirroring `ce-work-beta` argument shape.
- R2. `lfg` accepts an `mcp:<name>[,<name>...]` token (e.g. `mcp:perplexity,codex`) that designates additional MCP/agent providers to auto-invoke during the pipeline.
- R3. When delegation is active, the work phase invokes `ce-work-beta` with `delegate:codex` instead of `ce-work`. Codex CLI is primary; if `codex` CLI is unavailable, the skill falls back to `mcp__codex__codex` for the same phase.
- R4. Pipeline reads `.compound-engineering/config.local.yaml` keys for `lfg`-level defaults: `lfg_delegate` (mirrors `work_delegate`), `lfg_mcp_providers` (comma-separated list), and `lfg_adversarial_review` (`true`/`false`, default `true`).
- R5. After `ce-code-review` (step 3), spawn a parallel adversarial review lane via `mcp__codex__codex` with an adversarial prompt scoped to the same diff. Merge findings; autofix anything actionable.
- R6. After autofix, items requiring human judgment or where confidence is low are listed in a `## Human-Judgment Items` section appended to the PR body (or to the residual fallback file when no PR exists), so the user can re-direct.
- R7. Configured MCPs auto-invoke at appropriate phases when capable: `perplexity` → research aid passed to `ce-plan`/`ce-work-beta` for external lookups; `codex` (the MCP form) → activated as the adversarial-review lane and as the delegation fallback.
- R8. Behavior is gated by capability: if a configured MCP is not actually loaded in the host platform, `lfg` notes "provider not available" and continues without aborting.
- R9. All other existing pipeline steps (test-browser, commit-push-pr, residual handoff, persistent autofix commit) remain functionally identical.
- R10. The `.compound-engineering/config.local.example.yaml` file documents the new keys.

---

## Scope Boundaries

- Not changing `ce-work-beta` itself; `lfg` only routes to it.
- Not building a generic plugin/agent registry. Auto-invoke is hardcoded to a small known set: `codex` and `perplexity`. Unknown names are accepted into the list but only emit a "no built-in handler" note.
- Not adding a UI/menu to `lfg`. It remains argument- and config-driven and `disable-model-invocation: true`.
- Not modifying `ce-code-review`'s internal dispatch. The adversarial codex MCP pass is invoked from `lfg` directly, in parallel with the existing `ce-code-review` autofix call.
- Not introducing per-step provider scheduling DSL. Mapping from provider name to phase is fixed in this iteration.

### Deferred to Follow-Up Work

- Generic provider plug-in protocol (arbitrary MCP names with declarative phase mapping): future iteration once we see real demand.
- Slack / linear / etc. as configurable lfg providers.

---

## Context & Research

### Relevant Code and Patterns

- `plugins/compound-engineering/skills/lfg/SKILL.md` — existing pipeline; argument parsing currently only echoes `$ARGUMENTS`.
- `plugins/compound-engineering/skills/ce-work-beta/SKILL.md` — canonical pattern for argument-token + config-resolution chain (`delegate:codex` token, `Settings Resolution Chain`, pre-resolved `!\`...\`` config block, `delegation_active` state). Mirror this shape.
- `plugins/compound-engineering/skills/ce-work-beta/references/codex-delegation-workflow.md` — codex CLI fallback semantics, sandbox/consent model.
- `plugins/compound-engineering/skills/ce-code-review/SKILL.md` — already runs `ce-adversarial-reviewer` internally; lfg's added adversarial lane is the **codex MCP** lane, not a duplicate of the in-skill adversarial reviewer.
- `.compound-engineering/config.local.example.yaml` — config documentation surface.
- Global `~/.claude/CLAUDE.md` two-lane review pattern — explicit user preference for parallel Codex MCP lane.

### Institutional Learnings

- `docs/solutions/workflow/release-please-version-drift-recovery.md` — reminder that lfg goes through PR + `release:validate`, do not bypass.
- Skill-cache loading caveats from `AGENTS.md` — behavioral changes to lfg must be tested via skill-creator, not in-session.

### External References

- None required; pattern is local.

---

## Key Technical Decisions

- **Token shape:** Adopt `delegate:codex` / `delegate:local` and `mcp:a,b,c` tokens. Rationale: matches existing `ce-work-beta` token vocabulary, low cognitive cost, easy to parse with shell.
- **Codex CLI vs Codex MCP:** For *delegation* (work phase) prefer the CLI per `ce-work-beta` convention; the MCP is fallback. For the *adversarial review lane* use the MCP directly (`mcp__codex__codex`) — it's already designed for sidecar review and avoids spawning a second long-running CLI inside lfg.
- **Auto-invoke mapping is hardcoded, not data-driven:** `codex` → delegation+adversarial, `perplexity` → research aid for plan/work phases. Unknown names are accepted but no-op with a notice. Keeps the first iteration simple per scope-boundary discipline.
- **Adversarial lane runs in parallel with `ce-code-review` autofix, not after:** invoking concurrently halves wall time and matches the user's stated "parallel codex mcp adversarial review" requirement.
- **Findings merge:** `lfg` collects codex MCP adversarial findings as a JSON array (severity, file:line, title, body, suggested fix). Autofixable findings are applied directly via Edit; the rest are appended to the residual list and routed through the existing residual handoff (step 5).
- **Capability gate:** lfg checks for `codex` on `$PATH` and for `mcp__codex__codex` / `mcp__perplexity__*` tools at run-time before invoking; missing providers degrade gracefully.

---

## Open Questions

### Resolved During Planning

- *Should perplexity auto-trigger on every run?* No — only when listed in `mcp:` token or `lfg_mcp_providers` config, and only at plan/work phase as a research consult, not as a primary executor.
- *Should the adversarial codex-MCP review pass replace `ce-adversarial-reviewer`?* No — it complements; ce-code-review's internal adversarial reviewer remains. The codex MCP lane is a **second model's perspective**, the explicit point of the two-lane pattern.

### Deferred to Implementation

- Exact prompt text for the codex MCP adversarial lane — drafted during U3 implementation; should ask codex to produce findings as JSON matching the same severity/file:line shape `ce-code-review` emits.
- Whether to push autofixes from the codex-adversarial lane in their own commit (`fix(review-codex): ...`) or fold into the existing `fix(review): apply autofix feedback`. Default: fold in to avoid commit-fragmentation.

---

## Implementation Units

- U1. **Argument parsing and config resolution at the top of lfg/SKILL.md**

**Goal:** Parse `delegate:codex|local`, `mcp:<list>`, and read `.compound-engineering/config.local.yaml` for `lfg_delegate`, `lfg_mcp_providers`, `lfg_adversarial_review` defaults. Establish resolved state variables: `delegation_active`, `delegate_source`, `mcp_providers` (list), `adversarial_review_active`.

**Requirements:** R1, R2, R4, R8

**Dependencies:** None

**Files:**
- Modify: `plugins/compound-engineering/skills/lfg/SKILL.md`
- Modify: `.compound-engineering/config.local.example.yaml`

**Approach:**
- Mirror `ce-work-beta`'s token-strip + `!\`...\`` pre-resolved config block + Settings Resolution Chain shape verbatim.
- After parsing `mcp:` token, normalize to lowercase comma-split list. Merge with config-default list.
- Capability detection: emit a `!\`command -v codex >/dev/null && echo yes || echo no\`` block so the agent knows whether codex CLI is available.

**Patterns to follow:**
- `plugins/compound-engineering/skills/ce-work-beta/SKILL.md` § "Argument Parsing" through "Settings Resolution Chain".

**Test scenarios:**
- Happy path: `delegate:codex mcp:perplexity,codex feature description...` → `delegation_active=true`, `mcp_providers=["perplexity","codex"]`, remaining `$ARGUMENTS` = `feature description...`.
- Edge case: no tokens, no config file → `delegation_active=false`, `mcp_providers=[]`, `adversarial_review_active=true` (default).
- Edge case: config has `lfg_delegate: codex` and arg has `delegate:local` → arg wins, `delegation_active=false`.
- Error path: malformed `mcp:` token (`mcp:` with empty list) → treated as empty list, no error.
- Test expectation: behavioral; verify by running the skill via skill-creator with each input shape.

**Verification:**
- Skill-creator dry-run of each test scenario emits expected resolved state.

---

- U2. **Route work phase to ce-work-beta when delegation active; codex MCP fallback when CLI missing**

**Goal:** When `delegation_active=true`, step 2 invokes `ce-work-beta` with `delegate:codex` token. If `codex` CLI is not on PATH, ce-work-beta itself handles fallback per its own logic — but lfg should warn the user once at top-of-pipeline if codex CLI is missing AND codex MCP is also missing, in which case it disables delegation and falls back to `ce-work`.

**Requirements:** R3, R8

**Dependencies:** U1

**Files:**
- Modify: `plugins/compound-engineering/skills/lfg/SKILL.md` (step 2 block)

**Approach:**
- Replace the unconditional `Invoke the ce-work skill` with a branch:
  - `delegation_active && (codex_cli_available || codex_mcp_available)` → invoke `ce-work-beta` with `delegate:codex`.
  - Else → invoke `ce-work`. Log the decision.
- Keep the gate language ("Verify implementation occurred") identical regardless of branch.

**Patterns to follow:**
- The existing step 2 prose; minimal restructure.

**Test scenarios:**
- Happy path: delegation active + codex CLI present → ce-work-beta is invoked with `delegate:codex`.
- Fallback: delegation active + codex CLI missing + codex MCP present → ce-work-beta invoked (it picks MCP internally per its own fallback rules).
- Degrade: delegation active + neither codex CLI nor MCP → emits notice, invokes ce-work, sets `delegation_active=false` for downstream phases.
- Test expectation: behavioral via skill-creator with mocked PATH.

**Verification:**
- Pipeline produces a plan + work step regardless of provider availability.

---

- U3. **Parallel codex-MCP adversarial review lane after step 3**

**Goal:** Add a sub-step (3b) that, when `adversarial_review_active=true` and codex MCP is loaded (or `codex` is in `mcp_providers`), invokes `mcp__codex__codex` in parallel with `ce-code-review` (step 3) with an adversarial prompt; collects structured findings; merges autofixable findings into the same autofix pass; appends non-autofixable findings to the residual list consumed by step 5.

**Requirements:** R5, R6, R7, R8

**Dependencies:** U1

**Files:**
- Modify: `plugins/compound-engineering/skills/lfg/SKILL.md` (step 3 block; add 3b)
- Create: `plugins/compound-engineering/skills/lfg/references/codex-adversarial-prompt.md` (the adversarial prompt template + findings JSON schema)

**Approach:**
- Build an OS-temp scratch dir for this run (`mktemp -d -t lfg-codex-adv-XXXXXX`).
- Compose the adversarial prompt by reading `references/codex-adversarial-prompt.md`, splicing in the diff, plan path, and the explicit instruction: "Return ONLY a JSON array of findings: `[{severity, file, line, title, body, autofixable, suggested_fix}, ...]`."
- Spawn `mcp__codex__codex` and the regular `ce-code-review mode:autofix plan:<path>` in the same response (parallel tool use).
- After both return:
  - Apply autofixable findings via Edit (same commit pass that step 4 will commit).
  - Add non-autofixable findings to the in-memory residual list, tagged `source: codex-adversarial`.
- If codex MCP is unavailable, skip 3b entirely with a one-line notice and continue the existing pipeline.

**Patterns to follow:**
- `ce-code-review`'s parallel-dispatch shape and JSON finding schema (severity, file:line, title, body) — copy the keys so step 5's residual consumer doesn't need a second branch.

**Test scenarios:**
- Happy path: codex MCP loaded → step 3 + step 3b run in parallel; findings merged into one autofix commit; residuals from both lanes flow into step 5.
- Edge case: codex MCP returns invalid JSON → log a parse failure as a single residual finding ("codex adversarial returned unparseable output"), do not abort.
- Edge case: codex MCP times out → record as a single residual; pipeline continues.
- Capability gate: codex MCP not loaded and `codex` not in `mcp_providers` → step 3b is skipped silently.
- Test expectation: behavioral via skill-creator dispatch test.

**Verification:**
- A run with codex MCP available produces additional residual entries (or applied autofixes) attributed to `codex-adversarial`.

---

- U4. **Perplexity auto-invoke as research aid (plan + work phases)**

**Goal:** When `perplexity` is in `mcp_providers`, lfg passes a "perplexity available" hint into step 1 (`ce-plan`) and step 2 (work) so they can opt into `mcp__perplexity__perplexity_search` / `_research` for external grounding.

**Requirements:** R2, R7, R8

**Dependencies:** U1

**Files:**
- Modify: `plugins/compound-engineering/skills/lfg/SKILL.md` (step 1 and step 2 invocations)

**Approach:**
- When `perplexity` is in `mcp_providers`, prepend a context note to the `ce-plan`/`ce-work-beta` argument: `mcp_hint:perplexity` (or pass the hint as a leading line). Both downstream skills already perform research — the hint signals "perplexity is preferred for external lookups in this run."
- If perplexity MCP isn't actually loaded (capability check), drop the hint silently.

**Patterns to follow:**
- `ce-plan` Phase 1.2's "Decide on External Research" — feed a single concise hint, don't reshape the skill's logic.

**Test scenarios:**
- Happy path: `mcp:perplexity` token + perplexity MCP loaded → ce-plan invocation argument contains `mcp_hint:perplexity`.
- Edge case: token present but MCP missing → no hint passed; one-line "perplexity not available" notice in lfg output.
- Test expectation: behavioral via skill-creator argument inspection.

**Verification:**
- Captured ce-plan argument string contains the hint when expected.

---

- U5. **Human-judgment items section in residual handoff**

**Goal:** Step 5's composed `## Residual Review Findings` section gains a `## Human-Judgment Items` companion subsection (or unified section with a `human-judgment` tag per item) for findings flagged by either `ce-code-review` or the codex adversarial lane as low-confidence-autofix or "needs human decision". User asked these be applied anyway but listed for redirect.

**Requirements:** R6

**Dependencies:** U3

**Files:**
- Modify: `plugins/compound-engineering/skills/lfg/SKILL.md` (step 5 composition rules)

**Approach:**
- When composing the markdown for step 5, if any finding has `confidence: low` or `requires_human_judgment: true`, list it under a dedicated subsection with the heading `### Items applied with low confidence (please verify)`. Each entry shows: severity, file:line, title, the autofix that was applied, and a one-line reason the agent had doubt.
- Items where autofix was NOT applied (truly blocked on human decision) go under the existing failed/no_sink buckets per current behavior.

**Test scenarios:**
- Findings with mixed confidence levels → high-confidence appear in the regular section, low-confidence in the dedicated subsection.
- All-high-confidence run → dedicated subsection omitted entirely.

**Verification:**
- Generated PR-body markdown matches expected structure across mixed-confidence runs.

---

- U6. **Documentation: example config + skill description update**

**Goal:** Document new config keys and tokens.

**Requirements:** R10

**Dependencies:** U1, U2, U3, U4, U5

**Files:**
- Modify: `.compound-engineering/config.local.example.yaml` (add `lfg_delegate`, `lfg_mcp_providers`, `lfg_adversarial_review`)
- Modify: `plugins/compound-engineering/skills/lfg/SKILL.md` frontmatter `argument-hint` and a brief "Tokens & Config" section near the top.

**Test scenarios:**
- `bun run release:validate` passes after edits.
- Test expectation: structural; verified by `bun run release:validate` and visual review.

**Verification:**
- `bun run release:validate` exits 0.

---

## System-Wide Impact

- **Interaction graph:** `lfg` now invokes `ce-work-beta` (in addition to `ce-work`), and adds a parallel `mcp__codex__codex` call alongside `ce-code-review`. No other skills change.
- **Error propagation:** Capability gates degrade gracefully — missing CLI/MCP never aborts the pipeline, only emits a notice and falls through to the legacy path.
- **State lifecycle risks:** Parallel codex MCP adversarial pass writes findings to OS-temp scratch, applied via Edit before step 4's commit — same commit window as the existing autofix pass, no new commit fragmentation.
- **API surface parity:** The new tokens/config keys are additive; absence preserves existing behavior identically.
- **Integration coverage:** Behavioral testing via skill-creator (per AGENTS.md), since lfg is a markdown skill loaded into agent prompt.
- **Unchanged invariants:** Steps 4 (commit autofix), 5 (residual handoff), 6 (test-browser), 7 (PR), 8 (DONE) remain identical when delegation/MCP features are off (default).

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Skill-cache caveat: in-session edits to `lfg/SKILL.md` won't take effect mid-session | Test exclusively via skill-creator; do not attempt to validate by re-running `/lfg` in the same session |
| Codex MCP returning malformed JSON breaks merge step | Wrap parse in a try; on failure log a single residual entry, never abort |
| Two parallel autofix lanes (ce-code-review + codex MCP adversarial) racing on the same file | Apply codex-adversarial autofixes only after `ce-code-review` returns; serialize the Edits even though the agent dispatches the analysis in parallel |
| User has codex CLI but it's an old version that doesn't accept `model_reasoning_effort` | Inherits ce-work-beta behavior; not lfg's concern |
| `mcp:` arg list collides with future general syntax | Reserve token prefix `mcp:` and document it; unknown providers no-op with notice |

---

## Documentation / Operational Notes

- Update `plugins/compound-engineering/README.md` lfg row if it lists args/config.
- Add a changelog-friendly conventional commit (`feat(lfg): ...`) when shipping.
- Ensure `STALE_SKILL_DIRS` etc. in `src/utils/legacy-cleanup.ts` do not need entries (no removals here, only additions).

---

## Sources & References

- `plugins/compound-engineering/skills/lfg/SKILL.md`
- `plugins/compound-engineering/skills/ce-work-beta/SKILL.md`
- `plugins/compound-engineering/skills/ce-work-beta/references/codex-delegation-workflow.md`
- `plugins/compound-engineering/skills/ce-code-review/SKILL.md`
- `.compound-engineering/config.local.example.yaml`
- Global `~/.claude/CLAUDE.md` two-lane review pattern
