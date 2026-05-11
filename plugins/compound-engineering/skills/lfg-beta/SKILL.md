---
name: lfg-beta
description: "[BETA] Full autonomous engineering workflow with optional Codex CLI delegation and configurable MCP/CLI/skill providers (e.g. perplexity)"
argument-hint: "[feature description] [delegate:codex|delegate:local] [providers:perplexity,codex,...] [adversarial:on|off]"
disable-model-invocation: true
---

CRITICAL: You MUST execute every step below IN ORDER. Do NOT skip any required step. Do NOT jump ahead to coding or implementation. The plan phase (step 1) MUST be completed and verified BEFORE any work begins. Violating this order produces bad output.

When invoking any skill referenced below, resolve its name against the available-skills list the host platform provides and use that exact entry. Some platforms list skills under a plugin namespace (e.g., `compound-engineering:ce-plan`); others list the bare name. Invoking a short-form guess that isn't in the list will fail — always match a listed entry verbatim before calling the Skill/Task tool.

## What this beta adds over `lfg`

- **Codex CLI delegation** for the work phase, routing through `ce-work-beta delegate:codex` instead of `ce-work`.
- **A configurable provider list** — name any MCP server, CLI tool, or installed skill, and lfg-beta auto-detects what's actually available and surfaces those capabilities to downstream skills.
- **A parallel codex MCP adversarial review lane** alongside `ce-code-review` when the codex MCP is loaded.

## Tokens & Config

Parse `$ARGUMENTS` for the optional tokens below. Strip each recognized token before treating the remainder as `feature_description` (passed to `ce-plan`).

| Token | Example | Effect |
|-------|---------|--------|
| `delegate:codex` | `delegate:codex` | Activate Codex CLI delegation for the work phase (routes step 2 to `ce-work-beta`) |
| `delegate:local` | `delegate:local` | Force the work phase to use `ce-work` even if config enables delegation |
| `providers:<list>` | `providers:perplexity,codex,context7` | Comma-separated provider names (MCP servers, CLI tools, or installed skills) to surface to downstream skills as available helpers |
| `adversarial:on` / `adversarial:off` | `adversarial:off` | Per-run override of `adversarial_review_active` (step 3 codex-MCP review lane) |

### Token normalization

- **Case:** lowercase before matching. `Delegate:Codex` and `Providers:Perplexity` are valid.
- **Whitespace and stray commas:** split the list on commas, trim each entry, drop empties. `providers:perplexity, codex` → `["perplexity","codex"]`. `providers:,perplexity,` → `["perplexity"]`.
- **Empty `providers:`** sets `requested_providers=[]` from the argument source.
- **`providers:none`** is an explicit suppression signal from the argument side: it overrides any config-supplied list entirely (no union) and yields `requested_providers=[]`. It does NOT mix with other names — `providers:none,perplexity` is treated as `providers:none` plus a one-line notice that `perplexity` was discarded due to the `none` sentinel.
- **Provider name validation:** after lowercasing and trimming, each name must match `^[a-z0-9_-]{2,32}$`. Names that fail this check are dropped with a one-line notice: `Provider name <repr> rejected — must match [a-z0-9_-], length 2-32.` Use a quoted repr (`'$(whoami)'`) so the user sees what was rejected. This guards both `command -v` injection and downstream prompt-injection via `providers_hint:`.
- **Repeated `delegate:*` tokens:** last token wins.
- **Repeated `adversarial:*` tokens:** last token wins. Argument tokens override config; the `adversarial:` argument token is the documented per-run override.
- **Unknown delegate value** (e.g., `delegate:gemini`): ignore the token, emit a one-line notice, continue with config/default.
- **Bare mention of a provider name in `feature_description`** (e.g., "fix codex converter bugs") does NOT activate it — only the explicit token (or its fuzzy-activation phrasing for `delegate:`) counts.
- **Fuzzy delegation phrases — explicit tokens always win.** If any explicit `delegate:codex` or `delegate:local` token is present after parsing, ignore all fuzzy phrases. Only when no explicit `delegate:*` token is present do fuzzy phrases apply.
- **Fuzzy delegation activation:** `use codex`, `delegate to codex`, `codex mode` → `delegate:codex`. Example fires: "fix the bug, use codex". Example doesn't fire: "fix codex converter bugs".
- **Fuzzy delegation deactivation:** `no codex`, `local mode`, `standard mode` → `delegate:local`.
- **Conflicting fuzzy phrases — deactivation wins.** If both activation and deactivation phrases match (e.g., "no codex mode"), resolve to `delegate:local`. Negation phrases beat positive ones because a user typing "no" is more likely opting out than opting in.

### Config (pre-resolved)

!`(top=$(git rev-parse --show-toplevel 2>/dev/null); [ -n "$top" ] && cat "$top/.compound-engineering/config.local.yaml" 2>/dev/null) || echo '__NO_CONFIG__'`

If the block above contains YAML, extract the keys below. If `__NO_CONFIG__`, all settings fall through to defaults. If it shows an unresolved command string, use the native file-read tool to read `.compound-engineering/config.local.yaml` from the repo root; if absent, fall through to defaults. Unrecognized values fall through to defaults.

Config keys:
- `lfg_beta_delegate` -- `codex` or default `false` (mirrors `ce-work-beta`'s `work_delegate`)
- `lfg_beta_providers` -- comma-separated provider list (e.g. `perplexity,codex,context7`); default empty
- `lfg_beta_adversarial_review` -- `true` (default) or `false` to disable the parallel codex-MCP adversarial lane

### Settings Resolution

For `delegation_active` and `adversarial_review_active`, argument tokens override config; config overrides hard defaults. The argument-side tokens are `delegate:codex|local` (or their fuzzy phrases) and `adversarial:on|off`.

For `requested_providers`:
- If the argument side supplied `providers:none`, the resolved list is `[]` regardless of config.
- Otherwise the argument list and config list are **unioned** (deduped, lowercased), since they declaratively name available helpers rather than mutually exclusive choices.

Hard defaults: `delegation_active=false`, `requested_providers=[]`, `adversarial_review_active=true`.

### Provider capability detection

For each name in `requested_providers`, resolve it to one or more **capability surfaces**:

| Surface | How to detect | Tool/skill name shape |
|---------|---------------|-----------------------|
| MCP tools | scan the available-tools list for `mcp__<name>__*` | runtime tool-list lookup |
| CLI on PATH | shell `command -v <name>` returns 0 | `<name>` |
| Installed skill | `<name>` appears in the available-skills list (with or without a plugin namespace prefix) | exact entry from the list |

A single name may resolve to multiple surfaces (e.g., `codex` is both a CLI and an MCP). Resolve every detected surface — they are not exclusive.

**Codex CLI probe (pre-resolved):**

!`(command -v codex >/dev/null 2>&1 && ((codex --version 2>/dev/null | head -1 | grep -qiE 'codex' && echo "codex_cli=yes") || echo "codex_cli=collision")) || echo "codex_cli=no"`

Interpret the line above:
- `codex_cli=yes` — a `codex` binary is on PATH and `codex --version` mentions `codex`. Set `codex_cli_available=true`.
- `codex_cli=collision` — a binary named `codex` exists on PATH but does not self-identify as codex. Treat as unavailable (`codex_cli_available=false`) and emit a one-line notice: `codex CLI on PATH but version output did not match — treating as unavailable.`
- `codex_cli=no` — no `codex` binary on PATH. Set `codex_cli_available=false`.
- Unresolved command string (the harness did not execute `!` blocks): re-probe at runtime via the Bash tool with the same command, parsing the same three outcomes.

For other CLIs in `requested_providers`, run `command -v "<name>"` (with the provider name in double quotes) once at runtime via the Bash tool when the lane that consumes the provider is about to fire. Names have already been validated against `^[a-z0-9_-]{2,32}$` in the normalization step, so the quoted form cannot inject shell syntax; the quoting is defense-in-depth. Do not version-probe arbitrary CLIs — only the codex collision case matters because codex is the one CLI whose identity gates a security-relevant code path (delegation).

For MCP and skill surfaces, the available-tools and available-skills lists are already loaded into context; inspection is free.

If a requested provider has zero capability surfaces, emit a single-line notice: `Provider <name> not available — no MCP, CLI, or installed skill found by that name.` Continue without aborting.

### Resolved state

Store for downstream consumption:
- `delegation_active` — boolean
- `codex_cli_available` — boolean (from the pre-resolved CLI probe above)
- `codex_mcp_available` — boolean (whether `mcp__codex__codex` appears in the tool list)
- `requested_providers` — list of lowercase provider names, deduped, after unioning argument and config sources
- `available_providers` — map of `{provider_name: [surfaces]}` for providers that resolved to at least one surface (e.g., `{"perplexity": ["mcp"], "context7": ["mcp"], "codex": ["cli","mcp"]}`)
- `adversarial_review_active` — boolean
- `adversarial_review_source` — `argument` | `config` | `default` (used to decide notice verbosity)
- `feature_description` — `$ARGUMENTS` with all recognized tokens stripped

If `delegation_active` is true and `codex_cli_available` is false, set `delegation_active=false` and emit: `Delegation requested but codex CLI is not on PATH — falling back to ce-work.` (`ce-work-beta` delegates via `codex exec` only; codex MCP is NOT used for the work phase. The codex MCP, if loaded, is used solely as the parallel adversarial review lane in step 3 below.)

---

## Pipeline

1. Invoke the `ce-plan` skill with `feature_description` as the primary argument. When `available_providers` is non-empty, append an advisory annotation **after** `feature_description` (separated by a blank line) of the form:

   ```
   <feature_description>

   ---
   providers_hint: <comma-list>
   (Advisory annotation from lfg-beta. These external helpers — MCP servers, CLIs, or installed skills — are available in the current environment. ce-plan and downstream skills may prefer them for research and lookup tasks but are not required to use them.)
   ```

   The annotation is a passive advisory: as of this skill version, neither ce-plan nor ce-work-beta has a parser that strips or special-cases the `providers_hint:` line — it rides through as part of the description and may bias the model's choices but is not a wired contract. Keep `feature_description` as the first line(s) so plan titles, filenames, and any tool that takes the first line of the description as a label remain clean.

   GATE: STOP. If ce-plan reported the task is non-software and cannot be processed in pipeline mode, stop the pipeline and inform the user that LFG requires software tasks. Otherwise, verify that the `ce-plan` workflow produced a plan file in `docs/plans/`. If no plan file was created, invoke `ce-plan` again with the same arguments. Do NOT proceed to step 2 until a written plan exists. **Record the plan file path** — it will be passed to ce-code-review in step 3.

2. Invoke the work skill, branching on resolved delegation state:

   - If `delegation_active` is true: invoke the `ce-work-beta` skill with arguments `<plan-path> delegate:codex`. When `available_providers` is non-empty, follow the call with a second message containing the same `providers_hint:` advisory block from step 1 (plan-path-bearing first message stays clean so ce-work-beta's plan-path detection — which expects a file path — is not disturbed). `ce-work-beta` delegates via `codex exec` (CLI). If the CLI is missing it disables delegation internally and runs locally — that fallback path is owned by `ce-work-beta` and is the canonical source of truth for delegation behavior.
   - Else: invoke the `ce-work` skill with `<plan-path>`. Same rule for the providers_hint advisory: send as a follow-up message if applicable.

   Log the chosen branch in one line (`Work phase: ce-work-beta (delegate:codex)` or `Work phase: ce-work`).

   GATE: STOP. Verify that implementation work was performed — files were created or modified beyond the plan. Do NOT proceed to step 3 if no code changes were made.

3. **Review phase — codex lane runs first (analysis-only against a frozen diff), then ce-code-review runs (which may apply autofixes).**

   Earlier versions of this skill dispatched both lanes in parallel. That created a write-race: `ce-code-review mode:autofix` mutates files while the codex lane is analyzing line numbers in the same files. Codex returns findings keyed to pre-autofix line numbers, then the orchestrator applies codex's `suggested_fix` at lines that no longer correspond to the original code. The serialization below eliminates that window.

   Two lanes:

   - **Codex MCP adversarial lane** runs only when `adversarial_review_active` is true AND `codex_mcp_available` is true. When the gate is closed, skip directly to the Claude lane and emit one notice. **Suppress the notice when the gate closes solely because `adversarial_review_active` was default-derived AND codex MCP is unavailable** — that combination means the user did not explicitly enable the lane, so the skip is silent. Otherwise emit `Codex adversarial lane skipped: <reason>`.
   - **Claude lane:** invoke the `ce-code-review` skill with `mode:autofix plan:<plan-path-from-step-1>`. Pass the plan file path so ce-code-review can verify requirements completeness.

   Note: `providers:codex` controls only the providers_hint advisory in steps 1 and 2; it does NOT gate the codex MCP adversarial lane. The lane is gated by `adversarial_review_active` AND `codex_mcp_available` independent of the `providers:` list.

   **Composing and dispatching the codex MCP call (lane 1):**
   1. Resolve the diff base before composing the prompt. Order of preference:
      - If `gh pr view --json baseRefName` returns a base ref, use `git merge-base "origin/<baseRefName>" HEAD` to compute a base SHA.
      - Else use `git merge-base origin/main HEAD` (fall through to `origin/master` if main does not exist).
      - Else use `git rev-parse HEAD~1`.

      Capture the resolved base SHA as `<base_sha>`. If all three steps fail, skip the codex lane and emit `Codex adversarial lane skipped: could not resolve diff base.`
   2. Create an OS-temp scratch dir: `mktemp -d -t lfg-beta-codex-adv-XXXXXX`. Capture the absolute path as `<scratch_dir>`.
   3. Capture the diff to a frozen file so the prompt and post-processing read the same snapshot regardless of what the Claude lane does later: `git diff <base_sha>...HEAD > "<scratch_dir>/diff.patch"`.
   4. Read `references/codex-adversarial-prompt.md` for the prompt template and findings JSON schema.
   5. Compose the prompt by splicing in the plan path, the contents of `<scratch_dir>/diff.patch`, the resolved `<base_sha>` (so codex's `file:line` anchors reference the same snapshot), and the schema instruction. The prompt instructs codex to analyze only and return JSON — it must not modify any files.
   6. Invoke `mcp__codex__codex` with that prompt. Wait for it to return before dispatching lane 2.

   **After the codex lane returns, run the Claude lane:**
   - Invoke `ce-code-review` with `mode:autofix plan:<plan-path-from-step-1>`. Wait for it to return.

   **After both lanes return, process findings:**
   - Read `ce-code-review`'s Residual Actionable Work summary.
   - Parse codex-MCP output as JSON. If parsing fails, record a single residual entry titled `codex adversarial returned unparseable output` tagged `source: codex-adversarial`, `severity: low`, `owner: downstream-resolver`, `fingerprint: codex-unparseable` and continue.
   - For each codex finding, check whether ce-code-review's autofix already modified the target file (compare `git diff --name-only HEAD` against the finding's `file`). If the file changed, mark the finding as `stale_anchor: true` and treat it as not-autofixable for this run — append to residual list with a note explaining the anchor drift. Do NOT apply `suggested_fix` in that case.
   - For remaining codex findings (file untouched by ce-code-review), apply `suggested_fix` via Edit **only when ALL of the following are true**:
     - `autofixable: true`
     - `requires_human_judgment` is false or absent
     - `confidence` is `high` (or absent — codex prompts that omit confidence default to high-quality findings; treat absent as high)
   - Any finding that fails the autofix gate above — including `autofixable: true` findings gated out by judgment or low confidence — gets appended to the residual list with synthesized fields the residual handoff (step 5) expects: `owner: downstream-resolver`, `source: codex-adversarial`, `autofix_class: manual` (or `gated_auto` when `suggested_fix` is non-empty but the judgment/confidence gate blocked autofix). Preserve `confidence`, `requires_human_judgment`, `severity`, `file`, `line`, `title`, `body`, and `suggested_fix` on the finding object so step 5 can render them.
   - If codex MCP times out or errors, record a single residual (`codex adversarial unavailable: <reason>`, `severity: low`, `owner: downstream-resolver`, `fingerprint: codex-unavailable-<reason-slug>`) and continue. Never abort the pipeline. The `fingerprint` field exists so step 5 can dedup repeat unavailability against any same-fingerprint entry already present in the current PR body's `## Residual Review Findings` section — see step 5.5 below.

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
   5. **Fingerprint dedup against the existing PR body.** Before rendering bullets, fetch the current PR body (step 6 below performs the actual `gh pr view`; for dedup purposes capture it at the start of step 5). For each merged residual that has a `fingerprint` field (currently: codex-unavailable and codex-unparseable entries), if a bullet bearing the same fingerprint is already present in the existing `## Residual Review Findings` section, drop the new entry — do not re-emit. This prevents an unhealthy codex MCP from accumulating identical low-severity residuals across runs.
   6. **Items applied with low confidence subsection.** If any finding was autofixed AND carried `confidence: low` or `requires_human_judgment: true` at the time of autofix, append a subsection titled `### Items applied with low confidence (please verify)` after the bullets above. Each entry shows: severity, file:line, title, source lane, the autofix that was applied, and a one-line reason the agent had doubt. (Items not autofixed because they required human decision are already marked `[needs human review]` in the bullets above — do not duplicate them here.) If no findings qualify, omit the subsection. Note: with the step 3 autofix gate (high confidence AND not human-judgment), this subsection should typically be empty; it exists as a safety net if future changes loosen the gate.
   7. Detect the current branch's open PR without prompting:

      ```bash
      gh pr view --json number,url,body,state
      ```

   8. If an open PR exists, update it directly with `gh`; do not load any confirmation-driven PR update skill. **Preserve any manual content under the existing `## Residual Review Findings` section.** A "skill-template bullet" is a top-level list item that names a severity, file:line, title, and source lane in the documented format from step 5.4, or a child of those items. Anything else under the section — a Markdown subsection added by hand (other than `### Items applied with low confidence (please verify)` which the skill owns), a free-text paragraph, an admin's annotation appended to a bullet — counts as manual content. To preserve it: replace only the skill-owned bullets and the skill-owned `### Items applied with low confidence …` subsection. If manual content exists, append it under a clearly labeled `### Manual notes (preserved across runs)` subsection at the end of the residual section. Write the new body to an OS temp file, then run:

      ```bash
      gh pr edit PR_NUMBER --body-file BODY_FILE
      ```

   9. If no open PR exists, create a tracked fallback file at `docs/residual-review-findings/<branch-or-head-sha>.md` containing the composed section and the source PR-review run context. Stage only that file, commit it with `docs(review): record residual review findings`, and push the current branch. If an upstream exists, run `git push`. If no upstream exists, resolve a writable remote dynamically: prefer `origin` when present, otherwise use `git remote` and choose the first configured remote. Then run `git push --set-upstream <remote> HEAD`. This is the durable no-PR sink. Do not output DONE until either the existing PR body has been updated or this fallback file commit has been pushed. If both paths fail, stop and report the failed commands; do not silently proceed.

   Never block DONE on tracker filing failures once residuals have been durably recorded. A `no_sink` outcome is success only when the findings are present in the PR body or in the pushed fallback file.

6. Invoke the `ce-test-browser` skill with `mode:pipeline`.

7. Invoke the `ce-commit-push-pr` skill.

   This commits any remaining changes, pushes the branch, and opens a pull request. If a PR already exists for this branch (e.g., it predated this run, or step 5 updated one rather than creating a fallback file), skip PR creation but still commit and push any uncommitted changes. Detect with:

   ```bash
   gh pr view --json number,url,state 2>/dev/null
   ```

8. Output `<promise>DONE</promise>` when complete.

## Provider semantics

Provider names are **declarative hints**, not function calls. Listing a provider in `requested_providers` does not directly invoke anything; it tells lfg-beta which capabilities are available so downstream skills can opt to use them.

Two providers have first-class roles independent of the generic `providers_hint:` path:

- **`codex` CLI** — gates the work-phase delegation path (governed by `delegation_active` and the codex CLI version probe). Listing `codex` in `providers:` does NOT auto-enable delegation; use `delegate:codex` (or the matching config key) for that.
- **`codex` MCP** — gates the parallel adversarial review lane in step 3, subject to `adversarial_review_active`. The lane is gated by the MCP's presence in the tool list AND `adversarial_review_active`; **`providers:codex` does NOT gate the adversarial lane** (and is not required to enable it). The lane runs whenever the two gating conditions hold, regardless of the `providers:` list.

All providers — including `perplexity`, `context7`, `sentry`, `linear`, plus any future MCP/CLI/skill — flow through the same generic advisory path: they are detected, surfaced in `available_providers`, and named in the `providers_hint:` advisory block sent to `ce-plan` and the work skill (step 1 and step 2). Whether a downstream skill actually prefers any of them is the downstream skill's decision based on the task at hand; the hint is advisory, not a wired contract.

This skill does NOT include a registry of per-provider behaviors. If a future iteration needs special-cased pipeline phases for a new provider, add the wiring inline at the relevant step rather than building a generic plug-in protocol.

## Promotion to stable `/lfg`

When promoting this beta to stable, the standard mechanical changes (drop `-beta` suffix, drop `disable-model-invocation`, drop `[BETA]` prefix, swap README rows, remove test exemption) are necessary but not sufficient. The following coupling must also land in the same release:

- **`providers_hint:` consumers in `ce-plan` and `ce-work`** must be wired before the stable promotion or the advisory annotation will continue to ride through as part of the feature description text. Today neither skill parses the annotation — promoting the beta as-is means the contract remains passive on the stable side. Either: (a) land parser support in stable `ce-plan` and `ce-work` simultaneously, (b) reword the annotation so it is unambiguously safe to ignore (current beta wording is already safe-by-default), or (c) drop the advisory annotation from stable `/lfg` entirely.

Start with the Tokens & Config block now, then plan FIRST, then work. Never skip the plan.
