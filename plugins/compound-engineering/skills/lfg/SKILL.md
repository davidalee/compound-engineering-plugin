---
name: lfg
description: Full autonomous engineering workflow with optional delegation to Codex CLI/MCP and configurable MCP/agent providers (e.g. perplexity)
argument-hint: "[feature description] [delegate:codex|delegate:local] [mcp:perplexity,codex]"
disable-model-invocation: true
---

CRITICAL: You MUST execute every step below IN ORDER. Do NOT skip any required step. Do NOT jump ahead to coding or implementation. The plan phase (step 1) MUST be completed and verified BEFORE any work begins. Violating this order produces bad output.

When invoking any skill referenced below, resolve its name against the available-skills list the host platform provides and use that exact entry. Some platforms list skills under a plugin namespace (e.g., `compound-engineering:ce-plan`); others list the bare name. Invoking a short-form guess that isn't in the list will fail — always match a listed entry verbatim before calling the Skill/Task tool.

## Tokens & Config

Parse `$ARGUMENTS` for the following optional tokens. Strip each recognized token before treating the remainder as the feature description that gets passed to `ce-plan`.

| Token | Example | Effect |
|-------|---------|--------|
| `delegate:codex` | `delegate:codex` | Activate Codex delegation for the work phase (routes step 2 to `ce-work-beta`) |
| `delegate:local` | `delegate:local` | Force the work phase to use `ce-work` even if config enables delegation |
| `mcp:<list>` | `mcp:perplexity,codex` | Comma-separated list of MCP/agent provider names to auto-invoke at appropriate phases |

**Fuzzy activation:** Imperative phrases such as "use codex", "delegate to codex", "codex mode" count as `delegate:codex`. A bare mention of "codex" inside the feature description (e.g., "fix codex converter bugs") must NOT activate delegation.
**Fuzzy deactivation:** "no codex", "local mode", "standard mode" count as `delegate:local`.

### Config (pre-resolved)

!`(top=$(git rev-parse --show-toplevel 2>/dev/null); [ -n "$top" ] && cat "$top/.compound-engineering/config.local.yaml" 2>/dev/null) || echo '__NO_CONFIG__'`

If the block above contains YAML, extract the keys below. If `__NO_CONFIG__`, all settings fall through to defaults. If it shows an unresolved command string, use the native file-read tool to read `.compound-engineering/config.local.yaml` from the repo root; if absent, fall through to defaults. Unrecognized values fall through to defaults.

Config keys:
- `lfg_delegate` -- `codex` or default `false` (mirrors `ce-work-beta`'s `work_delegate`)
- `lfg_mcp_providers` -- comma-separated provider list (e.g. `perplexity,codex`); default empty
- `lfg_adversarial_review` -- `true` (default) or `false` to disable the parallel codex-MCP adversarial lane

### Settings Resolution

Resolve in this precedence:
1. **Argument tokens** — `delegate:*` and `mcp:*` from this invocation (highest priority)
2. **Config file** — keys above
3. **Hard defaults** — `delegation_active=false`, `mcp_providers=[]`, `adversarial_review_active=true`

### Capability detection (pre-resolved)

!`(command -v codex >/dev/null 2>&1 && echo "codex_cli=yes") || echo "codex_cli=no"`

Tool-availability checks for MCP providers happen at runtime: before invoking `mcp__codex__codex` or `mcp__perplexity__*`, confirm the tool name appears in the available-tools list. If a configured provider is unavailable, emit a single-line notice (`Provider <name> not available — skipping`) and continue without aborting.

Store the resolved state for downstream consumption:
- `delegation_active` — boolean
- `delegation_source` — `argument` | `config` | `default`
- `codex_cli_available` — boolean (from the capability probe above)
- `codex_mcp_available` — boolean (from runtime tool list inspection)
- `mcp_providers` — list of lowercase provider names, deduped, after merging argument and config sources
- `adversarial_review_active` — boolean
- `feature_description` — `$ARGUMENTS` with all recognized tokens stripped

If `delegation_active` is true but neither `codex_cli_available` nor `codex_mcp_available` is true, set `delegation_active=false` and emit: `Delegation requested but neither codex CLI nor codex MCP is available — falling back to ce-work.`

---

## Pipeline

1. Invoke the `ce-plan` skill with `feature_description`, prepending the line `mcp_hint:perplexity` to the argument string only when `perplexity` is in `mcp_providers` AND the perplexity MCP is loaded. The hint signals that perplexity is the preferred external-research surface for this run; `ce-plan` already runs its own research phase and uses the hint to bias tool selection.

   GATE: STOP. If ce-plan reported the task is non-software and cannot be processed in pipeline mode, stop the pipeline and inform the user that LFG requires software tasks. Otherwise, verify that the `ce-plan` workflow produced a plan file in `docs/plans/`. If no plan file was created, invoke `ce-plan` again with the same arguments. Do NOT proceed to step 2 until a written plan exists. **Record the plan file path** — it will be passed to ce-code-review in step 3.

2. Invoke the work skill, branching on resolved delegation state:

   - If `delegation_active` is true: invoke the `ce-work-beta` skill with arguments `<plan-path> delegate:codex`, prepending `mcp_hint:perplexity` when perplexity is in `mcp_providers` AND loaded. `ce-work-beta` owns its own CLI/MCP fallback per its codex-delegation workflow.
   - Else: invoke the `ce-work` skill with `<plan-path>`.

   Log the chosen branch in one line so the run record reflects the decision (`Work phase: ce-work-beta (delegate:codex)` or `Work phase: ce-work`).

   GATE: STOP. Verify that implementation work was performed — files were created or modified beyond the plan. Do NOT proceed to step 3 if no code changes were made.

3. Invoke the `ce-code-review` skill with `mode:autofix plan:<plan-path-from-step-1>`.

   Pass the plan file path from step 1 so ce-code-review can verify requirements completeness. Read the Residual Actionable Work summary the skill emits.

3b. **Parallel Codex-MCP adversarial review** (run only when `adversarial_review_active` is true AND (`codex` is in `mcp_providers` OR `codex_mcp_available` is true)).

   This lane runs in parallel with step 3. Both calls go in the same response so they execute concurrently.

   1. Create an OS-temp scratch dir for this run: `mktemp -d -t lfg-codex-adv-XXXXXX`. Capture the absolute path.
   2. Read `references/codex-adversarial-prompt.md` for the prompt template and findings JSON schema.
   3. Compose the prompt by splicing in the plan path, the diff (`git diff <base>...HEAD`), and the schema instruction.
   4. Invoke `mcp__codex__codex` with that prompt.
   5. After both step 3 and step 3b return:
      - Parse codex-MCP output as JSON. If parsing fails, record a single residual entry titled "codex adversarial returned unparseable output" tagged `source: codex-adversarial` and continue.
      - For each finding with `autofixable: true`, apply the suggested fix via Edit. **Serialize these Edits to run after `ce-code-review`'s autofix returns** to avoid concurrent writes to the same file.
      - For each finding with `autofixable: false` OR `confidence: low` OR `requires_human_judgment: true`, append to the residual list with the original `source: codex-adversarial` tag and the original confidence/judgment fields preserved.
   6. If codex MCP times out or errors, record a single residual ("codex adversarial unavailable: <reason>") and continue. Never abort the pipeline.

   If `adversarial_review_active` is false or codex MCP is unavailable, skip 3b silently with a one-line notice (`Codex adversarial lane skipped: <reason>`).

4. **Persist review autofixes** (REQUIRED after steps 3 and 3b, before residual handoff)

   Check `git status --short`. If autofix from step 3 OR step 3b changed files, stage only those review-fix files, commit them with `fix(review): apply autofix feedback`, and push the current branch before continuing. If an upstream exists, run `git push`. If no upstream exists, resolve a writable remote dynamically: prefer `origin` when present, otherwise use `git remote` and choose the first configured remote. Then run `git push --set-upstream <remote> HEAD`. Do not proceed to step 5, run browser tests, or output DONE while review autofix edits remain only in the working tree. If no files changed, explicitly note that there were no review autofixes to persist.

5. **Autonomous residual handoff** (only when steps 3 and 3b together produced one or more residual `downstream-resolver` findings; skip when both reported `Residual actionable work: none.`)

   Do not prompt the user. This step embraces the autopilot contract: residuals must become durable before DONE, but the agent never stops to ask.

   1. Load `references/tracker-defer.md` in **non-interactive mode**. Pass the merged residual actionable findings from steps 3 and 3b (or run artifacts when summaries were truncated). Preserve each finding's `source` tag (`ce-code-review` or `codex-adversarial`) so the tracker entries name the lane.
   2. Collect the structured return: `{ filed: [...], failed: [...], no_sink: [...] }`.
   3. Compose a `## Residual Review Findings` markdown section from the structured return:
      - For each item in `filed`: a bullet with severity, file:line, title, source lane, and a link to the tracker ticket URL.
      - For each item in `failed`: a bullet with severity, file:line, title, source lane, and the failure reason (e.g., `Defer failed: gh returned 401 — tracker unavailable`).
      - For each item in `no_sink`: a bullet with severity, file:line, title, and source lane inlined verbatim so the PR body or fallback file is the durable record.
   4. **Human-Judgment Items subsection.** If any finding (filed, failed, or no_sink) carried `confidence: low` or `requires_human_judgment: true` AND was autofixed, append a subsection titled `### Items applied with low confidence (please verify)` after the bullets above. Each entry shows: severity, file:line, title, source lane, the autofix that was applied, and a one-line reason the agent had doubt. Items where autofix was NOT applied because human decision was required stay in the failed/no_sink buckets above — do not duplicate them here. If no findings qualify, omit the subsection entirely.
   5. Detect the current branch's open PR without prompting:

      ```bash
      gh pr view --json number,url,body,state
      ```

   6. If an open PR exists, update it directly with `gh`; do not load any confirmation-driven PR update skill. Append or replace the `## Residual Review Findings` section in the current PR body, write the new body to an OS temp file, then run:

      ```bash
      gh pr edit PR_NUMBER --body-file BODY_FILE
      ```

   7. If no open PR exists, create a tracked fallback file at `docs/residual-review-findings/<branch-or-head-sha>.md` containing the composed section and the source PR-review run context. Stage only that file, commit it with `docs(review): record residual review findings`, and push the current branch. If an upstream exists, run `git push`. If no upstream exists, resolve a writable remote dynamically: prefer `origin` when present, otherwise use `git remote` and choose the first configured remote. Then run `git push --set-upstream <remote> HEAD`. This is the durable no-PR sink. Do not output DONE until either the existing PR body has been updated or this fallback file commit has been pushed. If both paths fail, stop and report the failed commands; do not silently proceed.

   Never block DONE on tracker filing failures once residuals have been durably recorded. A `no_sink` outcome is success only when the findings are present in the PR body or in the pushed fallback file.

6. Invoke the `ce-test-browser` skill with `mode:pipeline`.

7. Invoke the `ce-commit-push-pr` skill.

   This commits any remaining changes, pushes the branch, and opens a pull request. If step 5 already opened a PR (check with `gh pr view --json number,url,state 2>/dev/null`), skip PR creation but still commit and push any uncommitted changes.

8. Output `<promise>DONE</promise>` when complete.

## Provider auto-invoke mapping

The set of providers recognized in `mcp_providers` is fixed in this iteration:

- **`codex`** — activates the codex-MCP fallback for delegation (step 2) and the parallel adversarial lane (step 3b). Independent of `adversarial_review_active`, but `adversarial_review_active=false` still wins.
- **`perplexity`** — passed as `mcp_hint:perplexity` to `ce-plan` (step 1) and the work skill (step 2) so they prefer perplexity for external research lookups.
- **Any other name** — accepted into the list but emits one notice per unknown name (`Provider <name> in mcp_providers has no built-in handler — skipping`) and otherwise no-op. Reserved for a future iteration with a generic provider plug-in protocol.

Start with the Tokens & Config block now, then plan FIRST, then work. Never skip the plan.
