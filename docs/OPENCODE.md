# OpenCode integration

This repo's vLLM server works as a drop-in OpenAI-compatible provider for
[OpenCode](https://opencode.ai) (CLI and Desktop), for local, no-cloud
agentic coding. `scripts/configure-opencode.sh` wires up provider models,
context compaction settings, behavioral execution rules, and recovery plugins.

## What it does

```bash
scripts/configure-opencode.sh                    # local endpoint, default profile + rules + compaction
scripts/configure-opencode.sh --endpoint lan      # reachable from another machine on the LAN
scripts/configure-opencode.sh --profile qwen25-coder-14b
scripts/configure-opencode.sh --dry-run           # preview, touch nothing
scripts/configure-opencode.sh --skip-rules        # configure provider/compaction only
scripts/configure-opencode.sh --remove            # rollback provider, managed rules, and plugin
scripts/verify-opencode.sh                       # verify complete configuration and diagnostics
```

It performs a surgical merge into OpenCode's config file (`opencode.json` / `opencode.jsonc`):
- Writes `provider["scar-vllm"]` with served model limits and tool calling.
- Configures `compaction` (`auto: true`, `prune: true`, `reserved: 2000`).
- Installs global behavioral rules (`AGENTS.md`) into `<config_dir>/AGENTS.md`.
- Installs the custom compaction recovery plugin into `<config_dir>/plugins/compaction-recovery.js`.

Any other providers, MCP servers, agents, plugins, or preferences already in the
file are left untouched. It always creates timestamped backups before modifying
existing files (`.bak.<timestamp>`) and refuses to touch config files that are not
valid strict JSON (e.g. hand-edited with `//` comments).

The resulting model identifier is `scar-vllm/<served-model-name>` — e.g.
`scar-vllm/qwen3-coder-30b-a3b` for the default profile.

---

## CLI and Desktop share one config

Verified live on `scar.lab`: OpenCode Desktop is an Electron app that embeds
the *same* core `opencode` engine as the CLI. Its own Electron `userData` dir
(`~/.config/ai.opencode.desktop`) only holds browser-window state — the
embedded engine's config and data files (`~/.config/opencode/`,
`~/.local/share/opencode/`) are the *same files* the CLI uses.

Practical implications:
- Running `scripts/configure-opencode.sh` configures both CLI and Desktop.
- If Desktop is already running when configuring, restart it to pick up changes.
- `--remove` rolls back configuration for both.

---

## Why tool calling is enabled server-side

OpenCode is an agentic coding assistant — it reads/writes files and runs commands
via tool calls, not just chat completions. Both model profiles configure tool
calling via `EXTRA_VLLM_ARGS`:

| Profile | Parser | Why this one |
|---|---|---|
| `qwen3-coder-30b-a3b` | `qwen3_xml` | `qwen3_xml` is documented as the most stable choice for Qwen3-Coder (avoiding runaway `"!!!!"` loops reported on `qwen3_coder`). |
| `qwen25-coder-14b` | `hermes` | vLLM's standard tool-call parser for the Qwen2.5-Instruct family. |

---

## Context limits (`limit.context` / `limit.output`)

OpenCode cannot automatically infer the server's `--max-model-len` and defaults
to requesting large `max_tokens` (e.g. 32000), which vLLM rejects if it exceeds
the model's max context length.

`configure-opencode.sh` sets `limit.context` to the profile's `MAX_MODEL_LEN`
(32768 for Qwen3-Coder) and `limit.output` to a quarter of that (8192 tokens),
leaving the remaining context for conversation history, file contents, and tool results.

---

## Agent execution behavior & anti-looping rules

Local models (like Qwen3-Coder-30B) are capable of high-throughput agentic work
(~43 tok/s), but can easily get trapped in degenerative behaviors during long sessions:

- **Repeated planning**: Re-analyzing the whole codebase and producing repetitive multi-step roadmaps.
- **File re-reading loops**: Continually re-reading the same files before acting.
- **Excessive narration**: Narrating intended actions ("I need to examine X...") instead of using tools.
- **Compaction amnesia**: Losing implementation state after context compaction and restarting discovery.
- **Hesitation to edit**: Talking about code changes rather than applying them.

`config/opencode/AGENTS.md` establishes strict behavioral defaults to eliminate these loops:

### Execution discipline workflow

```text
Receive task
    ↓
Read repository instructions (AGENTS.md / rules)
    ↓
Read persistent implementation state if present (IMPLEMENTATION_STATUS.md)
    ↓
Inspect git status / git diff
    ↓
Inspect only relevant source files needed for current step
    ↓
Implement immediately
    ↓
Test / validate
    ↓
Update implementation state (IMPLEMENTATION_STATUS.md)
    ↓
Continue to next actionable item
```

### Action over narration

- **Bad:** "I need to examine endpoints.py to understand the current implementation."
- **Preferred:** `[read endpoints.py]`
- **Bad:** "The next step is to implement the API changes."
- **Preferred:** `[edit necessary files]` followed by `[run tests]`

---

## Persistent project state conventions

To make long-running tasks resilient across context compactions and separate sessions,
the global rules teach the agent to recognize standard persistent state files:

| File | Purpose | Intended usage |
|---|---|---|
| `AGENTS.md` | Repository-specific instructions, conventions, and constraints. | Read at task start and after compaction. Source of truth for repo rules. |
| `GOALS.md` | Target project end state, scope, architecture, and feature requirements. | Read to understand desired outcome. (Never assumed to be implemented without verifying code). |
| `IMPLEMENTATION_STATUS.md` | Persistent execution checkpoint: current objective, completed items, active task, test status, blockers. | Primary persistent memory across compactions and turns. Updated upon milestone completion. |

Repositories are not required to contain all three files; agents dynamically inspect
and utilize whatever combination is present.

---

## Context compaction & recovery

### What context compaction is
When an OpenCode session accumulates tokens approaching the model's context window
(32,768 tokens for Qwen3-Coder), OpenCode triggers **compaction**: older turns are
condensed into a summary so the session can continue without failing with a context overflow error.

### Why 32K models hit compaction frequently
In active coding sessions, reading large files, examining ASTs/greps, and inspecting build/test
outputs rapidly consumes 15K–25K tokens. In a 32K context window, compaction is a normal,
frequent lifecycle event.

### Why tool output pruning (`compaction.prune`) is critical
Historical tool outputs (e.g. a 500-line file read from 10 turns ago) remain in context
unless pruned. Enabling `"compaction": { "prune": true }` automatically strips obsolete
completed tool outputs older than recent turns, preserving critical conversational context
and drastically reducing unnecessary compaction cycles.

### Custom compaction recovery plugin (`compaction-recovery.js`)
By default, generic compaction summaries preserve conversational history and lose exact
technical details. `config/opencode/plugins/compaction-recovery.js` hooks into OpenCode's
`experimental.session.compacting` event to enforce a structured operational summary:

```text
## CURRENT OBJECTIVE
## CURRENT TASK
## COMPLETED WORK
## FILES MODIFIED
## FILES CURRENTLY BEING WORKED ON
## TESTS RUN & RESULTS
## KNOWN FAILURES & BLOCKERS
## IMPORTANT USER CONSTRAINTS
## NEXT ACTION
## DO NOT REPEAT
```

### Post-compaction recovery sequence
Following compaction, the agent does **NOT** attempt to re-discover the project or re-plan.
Instead, it executes this deterministic recovery procedure:

```text
Compaction
    ↓
1. Read repository instructions (AGENTS.md)
    ↓
2. Read IMPLEMENTATION_STATUS.md (if present)
    ↓
3. Run git status --short and inspect git diff
    ↓
4. Identify files modified but not yet validated
    ↓
5. Determine exact unfinished task
    ↓
6. Resume implementation immediately
```

If `IMPLEMENTATION_STATUS.md` conflicts with actual source code or test results,
the code and test results are authoritative.

---

## Behavioral rules management (`configure-opencode-rules.sh`)

`scripts/configure-opencode-rules.sh` can also be run independently:

```bash
scripts/configure-opencode-rules.sh            # install/update rules and plugin
scripts/configure-opencode-rules.sh --status    # check if installed files match repo
scripts/configure-opencode-rules.sh --diff      # show differences
scripts/configure-opencode-rules.sh --dry-run   # preview changes
scripts/configure-opencode-rules.sh --force     # force rewrite
scripts/configure-opencode-rules.sh --remove    # remove managed rules and plugin
```

### Managed-block safety
`AGENTS.md` is installed inside managed block delimiters:

```text
<!-- BEGIN SCAR-VLLM MANAGED RULES -->
...
<!-- END SCAR-VLLM MANAGED RULES -->
```

Any existing user rules outside these delimiters are preserved untouched.

---

## Verification script (`verify-opencode.sh`)

Run `scripts/verify-opencode.sh` to run a non-destructive audit of the complete configuration:

```bash
scripts/verify-opencode.sh
```

Checks verified:
- [x] OpenCode CLI binary installed and version detected.
- [x] `opencode.json(c)` exists and is strictly valid JSON.
- [x] `scar-vllm` provider configured with valid `/v1` endpoint.
- [x] Served Qwen model configured with `tool_call: true`, valid `limit.context`, and `limit.output`.
- [x] Compaction settings enabled (`compaction.auto: true`, `compaction.prune: true`, `compaction.reserved`).
- [x] Global `AGENTS.md` contains the valid managed block and execution discipline rules.
- [x] Custom compaction recovery plugin is installed in `<config_dir>/plugins/`.
- [x] No duplicate or corrupted marker blocks exist.

---

## Verifying end-to-end inference

```bash
opencode models | grep scar-vllm
opencode run --model scar-vllm/qwen3-coder-30b-a3b "say hi in one word"
```
