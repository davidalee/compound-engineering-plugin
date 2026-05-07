---
name: lfg
description: Full autonomous engineering workflow with optional delegation to Codex CLI and configurable MCP/agent providers (e.g. perplexity)
argument-hint: "[feature description] [delegate:codex|delegate:local] [mcp:perplexity,codex]"
disable-model-invocation: true
---

CRITICAL: You MUST execute every step below IN ORDER. Do NOT skip any required step. Do NOT jump ahead to coding or implementation. The plan phase (step 1) MUST be completed and verified BEFORE any work begins. Violating this order produces bad output.

When invoking any skill referenced below, resolve its name against the available-skills list the host platform provides and use that exact entry. Some platforms list skills under a plugin namespace (e.g., `compound-engineering:ce-plan`); others list the bare name. Invoking a short-form guess that isn't in the list will fail — always match a listed entry verbatim before calling the Skill/Task tool.

## Tokens & Config

Parse `$ARGUMENTS` for the following optional tokens. Strip each recognized token before treating the remainder as `feature_description` (passed to `ce-plan`).

| Token | Example | Effect |
|-------|---------|--------|
| `delegate:codex` | `delegate:codex` | Activate Codex delegation for the work phase (routes step 2 to `ce-work-beta`) |
| `delegate:local` | `delegate:local` | Force the work phase to use `ce-work` even if config enables delegation |
| `mcp:<list>` | `mcp:perplexity,codex` | Comma-separated list of MCP/agent provider names to auto-invoke at appropriate phases |

### Token normalization

- **Case:** lowercase before matching. `Delegate:Codex` and `MCP:Perplexity` are valid.
- **Empty `mcp:`:** an `mcp:` token with no list (or only whitespace/commas) sets `mcp_providers=[]` from the argument source.
- **Whitespace and stray commas:** split the list on commas, trim each entry, drop empties. `mcp:perplexity, codex` → `["perplexity","codex"]`. `mcp:,perplexity,` → `["perplexity"]`.
- **Repeated `delegate:*` tokens:** last token wins.
- **Unknown delegate value** (e.g., `delegate:gemini`): ignore the token and continue with config/default. Emit a one-line notice.
- **Bare mention of "codex" inside `feature_description`** (e.g., `fix codex converter bugs`) does NOT activate delegation — only the explicit `delegate:codex` token, or one of the imperative phrases below, counts.
- **Fuzzy activation:** `use codex`, `delegate to codex`, `codex mode` count as `delegate:codex`. Examples — fires: "fix the bug, use codex". Does not fire: "fix codex converter bugs".
- **Fuzzy deactivation:** `no codex`, `local mode`, `standard mode` count as `delegate:local`.

### Config (pre-resolved)

!`(top=$(git rev-parse --show-toplevel 2>/dev/null); [ -n "$top" ] && cat "$top/.compound-engineering/config.local.yaml" 2>/dev/null) || echo '__NO_CONFIG__'`

If the block above contains YAML, extract the keys below. If `__NO_CONFIG__`, all settings fall through to defaults. If it shows an unresolved command string, use the native file-read tool to read `.compound-engineering/config.local.yaml` from the repo root; if absent, fall through to defaults. Unrecognized values fall through to defaults.

Config keys:
- `lfg_delegate` -- `codex` or default `false` (mirrors `ce-work-beta`'s `work_delegate`)
- `lfg_mcp_providers` -- comma-separated provider list (e.g. `perplexity,codex`); default empty
- `lfg_adversarial_review` -- `true` (default) or `false` to disable the parallel codex-MCP adversarial lane

### Settings Resolution

For `delegation_active` and `adversarial_review_active`, argument tokens override config; config overrides hard defaults.

For `mcp_providers`, the argument list and config list are **unioned** (deduped, lowercased), since they declaratively name available helpers rather than mutually exclusive choices. To exclude a provider that config enables, pass `mcp:none` — this clears the list from the argument source and yields an empty `mcp_providers` regardless of config.

Hard defaults: `delegation_active=false`, `mcp_providers=[]`, `adversarial_review_active=true`.

### Capability detection (pre-resolved)

!`(command -v codex >/dev/null 2>&1 && echo "codex_cli=yes") || echo "codex_cli=no"`

Tool-availability checks for MCP providers happen at runtime: before invoking `mcp__codex__codex` or `mcp__perplexity__*`, confirm the tool name appears in the available-tools list. If a configured provider is unavailable, emit a single-line notice (`Provider <name> not available — skipping`) and continue without aborting.

Store the resolved state for downstream consumption:
- `delegation_active` — boolean
- `codex_cli_available` — boolean (from the capability probe above)
- `codex_mcp_available` — boolean (from runtime tool list inspection)
- `mcp_providers` — list of lowercase provider names, deduped, after unioning argument and config sources
- `adversarial_review_active` — boolean
- `adversarial_review_source` — `argument` | `config` | `default` (used to decide notice verbosity)
- `feature_description` — `$ARGUMENTS` with all recognized tokens stripped

If `delegation_active` is true and `codex_cli_available` is false, set `delegation_active=false` and emit: `Delegation requested but codex CLI is not on PATH — falling back to ce-work.` (`ce-work-beta` delegates via `codex exec` only; codex MCP is NOT used as a work-phase fallback. The codex MCP is used only as the parallel adversarial review lane in the review phase below.)

---

## Pipeline

1. Invoke the `ce-plan` skill with `feature_description`, prepending `mcp_hint:perplexity` to the argument string when `perplexity` is in `mcp_providers` AND the perplexity MCP is loaded. The hint signals that perplexity is the preferred external-research surface for this run; `ce-plan` already runs its own research phase and uses the hint to bias tool selection.

   GATE: STOP. If ce-plan reported the task is non-software and cannot be processed in pipeline mode, stop the pipeline and inform the user that LFG requires software tasks. Otherwise, verify that the `ce-plan` workflow produced a plan file in `docs/plans/`. If no plan file was created, invoke `ce-plan` again with `feature_description`. Do NOT proceed to step 2 until a written plan exists. **Record the plan file path** — it will be passed to ce-code-review in step 3.

2. Invoke the work skill, branching on resolved delegation state:

   - If `delegation_active` is true: invoke the `ce-work-beta` skill with arguments `<plan-path> delegate:codex`, prepending `mcp_hint:perplexity` when perplexity is in `mcp_providers` AND loaded. `ce-work-beta` delegates via `codex exec` (CLI). If the CLI is missing it disables delegation internally and runs locally — that fallback path is owned by `ce-work-beta` and is the canonical source of truth for delegation behavior.
   - Else: invoke the `ce-work` skill with `<plan-path>`.

   Log the chosen branch in one line (`Work phase: ce-work-beta (delegate:codex)` or `Work phase: ce-work`).

   GATE: STOP. Verify that implementation work was performed — files were created or modified beyond the plan. Do NOT proceed to step 3 if no code changes were made.

3. **Review phase — dispatch both lanes in a single response so they execute in parallel.**

   Two lanes:

   - **Claude lane:** invoke the `ce-code-review` skill with `mode:autofix plan:<plan-path-from-step-1>`. Pass the plan file path so ce-code-review can verify requirements completeness.
   - **Codex MCP adversarial lane:** runs only when `adversarial_review_active` is true AND `codex_mcp_available` is true (the runtime tool-list check from the capability section). When the gate is closed, dispatch only the Claude lane and emit one notice. **Suppress the notice when the gate closes solely because `adversarial_review_active` was default-derived AND codex MCP is unavailable** — that combination means the user did not explicitly enable the lane, so the skip is silent. Otherwise emit `Codex adversarial lane skipped: <reason>`.

   To dispatch in parallel, place both calls (the `ce-code-review` skill invocation AND the `mcp__codex__codex` invocation) in the same agent response — most platforms execute parallel tool calls concurrently.

   **Composing the codex MCP call:**
   1. Create an OS-temp scratch dir for this run: `mktemp -d -t lfg-codex-adv-XXXXXX`. Capture the absolute path.
   2. Read `references/codex-adversarial-prompt.md` for the prompt template and findings JSON schema.
   3. Compose the prompt by splicing in the plan path, the diff (`git diff <base>...HEAD`), and the schema instruction. The prompt itself instructs codex to analyze only and return JSON — it must not modify any files.
   4. Invoke `mcp__codex__codex` with that prompt.

   **After both lanes return:**
   - Read `ce-code-review`'s Residual Actionable Work summary.
   - Parse codex-MCP output as JSON. If parsing fails, record a single residual entry titled `codex adversarial returned unparseable output` tagged `source: codex-adversarial`, `severity: low`, `owner: downstream-resolver` and continue.
   - For each codex finding with `autofixable: true`, apply `suggested_fix` via Edit. **Serialize these Edits to run after `ce-code-review`'s autofix returns** to avoid concurrent writes to the same file.
   - For each codex finding with `autofixable: false` OR `confidence: low` OR `requires_human_judgment: true`, append it to the residual list. Synthesize the fields the residual handoff (step 5) expects: `owner: downstream-resolver`, `source: codex-adversarial`, `autofix_class: manual` (or `gated_auto` when `suggested_fix` is non-empty but `requires_human_judgment` is true). Preserve `confidence`, `requires_human_judgment`, `severity`, `file`, `line`, `title`, `body`, and `suggested_fix` on the finding object so step 5 can render them.
   - If codex MCP times out or errors, record a single residual (`codex adversarial unavailable: <reason>`, `severity: low`, `owner: downstream-resolver`) and continue. Never abort the pipeline.

4. **Persist review autofixes** (REQUIRED after step 3, before residual handoff)

   Check `git status --short`. If autofix from either lane changed files, stage only those review-fix files, commit them with `fix(review): apply autofix feedback`, and push the current branch before continuing. If an upstream exists, run `git push`. If no upstream exists, resolve a writable remote dynamically: prefer `origin` when present, otherwise use `git remote` and choose the first configured remote. Then run `git push --set-upstream <remote> HEAD`. Do not proceed to step 5, run browser tests, or output DONE while review autofix edits remain only in the working tree. If no files changed, explicitly note that there were no review autofixes to persist.

5. **Autonomous residual handoff** (run when step 3 produced one or more residual findings from either lane; skip when both lanes report `Residual actionable work: none.`)

   Do not prompt the user. This step embraces the autopilot contract: residuals must become durable before DONE, but the agent never stops to ask.

   1. **Build the merged residual list.** Combine `ce-code-review`'s residual actionable findings (downstream-resolver-owned) with codex-adversarial residuals (synthesized in step 3 with `owner: downstream-resolver`). Assign each merged finding a stable `finding_id` (e.g., `<source>-<index>`) before any external dispatch. Keep the merged list in memory, indexed by `finding_id`, until step 5 finishes — tracker-defer's return shape only echoes lightweight fields, so the original `confidence`, `requires_human_judgment`, `source`, `suggested_fix`, and `applied_autofix` flags must be looked up on the local list when rendering the markdown.
   2. Load `references/tracker-defer.md` in **non-interactive mode**. Pass the merged residual actionable findings (or run artifacts when summaries were truncated). Preserve each finding's `source` tag (`ce-code-review` or `codex-adversarial`) so tracker entries name the lane.
   3. Collect the structured return: `{ filed: [...], failed: [...], no_sink: [...] }`. Each entry references a `finding_id` from step 1 so the local list can be joined back.
   4. Compose a `## Residual Review Findings` markdown section. For every entry, look up the original finding by `finding_id` and render: severity, file:line, title, source lane, and the bucket-specific fields below. When the original finding has `requires_human_judgment: true` AND was NOT autofixed, append the inline marker `[needs human review]` to the bullet so the user can spot items requiring redirect even when they live in the standard buckets.
      - For each item in `filed`: bullet plus a link to the tracker ticket URL.
      - For each item in `failed`: bullet plus the failure reason (e.g., `Defer failed: gh returned 401 — tracker unavailable`).
      - For each item in `no_sink`: bullet inlined verbatim so the PR body or fallback file is the durable record.
   5. **Items applied with low confidence subsection.** If any finding was autofixed AND carried `confidence: low` or `requires_human_judgment: true` at the time of autofix, append a subsection titled `### Items applied with low confidence (please verify)` after the bullets above. Each entry shows: severity, file:line, title, source lane, the autofix that was applied, and a one-line reason the agent had doubt. (Items not autofixed because they required human decision are already marked `[needs human review]` in the bullets above — do not duplicate them here.) If no findings qualify, omit the subsection.
   6. Detect the current branch's open PR without prompting:

      ```bash
      gh pr view --json number,url,body,state
      ```

   7. If an open PR exists, update it directly with `gh`; do not load any confirmation-driven PR update skill. Append or replace the `## Residual Review Findings` section in the current PR body, write the new body to an OS temp file, then run:

      ```bash
      gh pr edit PR_NUMBER --body-file BODY_FILE
      ```

   8. If no open PR exists, create a tracked fallback file at `docs/residual-review-findings/<branch-or-head-sha>.md` containing the composed section and the source PR-review run context. Stage only that file, commit it with `docs(review): record residual review findings`, and push the current branch. If an upstream exists, run `git push`. If no upstream exists, resolve a writable remote dynamically: prefer `origin` when present, otherwise use `git remote` and choose the first configured remote. Then run `git push --set-upstream <remote> HEAD`. This is the durable no-PR sink. Do not output DONE until either the existing PR body has been updated or this fallback file commit has been pushed. If both paths fail, stop and report the failed commands; do not silently proceed.

   Never block DONE on tracker filing failures once residuals have been durably recorded. A `no_sink` outcome is success only when the findings are present in the PR body or in the pushed fallback file.

6. Invoke the `ce-test-browser` skill with `mode:pipeline`.

7. Invoke the `ce-commit-push-pr` skill.

   This commits any remaining changes, pushes the branch, and opens a pull request. If a PR already exists for this branch (e.g., it predated this run, or step 5 updated one rather than creating a fallback file), skip PR creation but still commit and push any uncommitted changes. Detect with:

   ```bash
   gh pr view --json number,url,state 2>/dev/null
   ```

8. Output `<promise>DONE</promise>` when complete.

## Provider auto-invoke mapping

This is a closed set of two recognized provider names. Unknown names exist only as a forward-compat reservation, not an extension point — adding a new built-in handler requires editing this skill.

- **`codex`** — when present in `mcp_providers` AND the codex MCP is loaded, enables the parallel adversarial review lane in step 3 (subject to `adversarial_review_active`). It does NOT change work-phase delegation; that is governed by `delegation_active` and the codex CLI alone, since `ce-work-beta` delegates via `codex exec`.
- **`perplexity`** — passed as `mcp_hint:perplexity` to `ce-plan` (step 1) and the work skill (step 2) when the perplexity MCP is loaded, so they prefer perplexity for external research lookups.
- **Any other name** — accepted into the list but emits one notice per unknown name (`Provider <name> in mcp_providers has no built-in handler — skipping`) and otherwise no-op.

Start with the Tokens & Config block now, then plan FIRST, then work. Never skip the plan.
