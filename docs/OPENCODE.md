# OpenCode integration

This repo's vLLM server works as a drop-in OpenAI-compatible provider for
[OpenCode](https://opencode.ai) (CLI and Desktop), for local, no-cloud
agentic coding. `scripts/configure-opencode.sh` wires it up.

## What it does

```bash
scripts/configure-opencode.sh                    # local endpoint, default profile
scripts/configure-opencode.sh --endpoint lan      # reachable from another machine on the LAN
scripts/configure-opencode.sh --profile qwen25-coder-14b
scripts/configure-opencode.sh --dry-run           # preview, touch nothing
scripts/configure-opencode.sh --remove            # rollback
```

It writes a `provider["scar-vllm"]` block into OpenCode's config file —
surgically: only that one key is touched, so any other providers, MCP
servers, agents, plugins, or preferences already in the file are left
exactly as they are. It always backs up the file first
(`opencode.json(c).bak.<timestamp>`, next to the original) and refuses to
touch a config file that isn't valid strict JSON (e.g. hand-edited with `//`
comments) rather than risk silently deleting them — merges are done with
`jq`, which has no concept of comments.

The resulting model identifier is `scar-vllm/<served-model-name>` — e.g.
`scar-vllm/qwen3-coder-30b-a3b` for the default profile. The served model
name comes directly from the model profile's `SERVED_MODEL_NAME`, not a
hardcoded string, so it always matches whatever vLLM is actually serving.

## CLI and Desktop share one config

Verified live on `scar.lab`, not assumed: OpenCode Desktop is an Electron
app that embeds the *same* core `opencode` engine as the CLI. Its own
Electron `userData` dir (`~/.config/ai.opencode.desktop`) is separate and
only holds browser-window state (cache, cookies, crash reports) — but the
embedded engine's own data/log files
(`~/.local/share/opencode/opencode.db`, `~/.local/share/opencode/log/opencode.log`)
are the *same files* the CLI uses, confirmed by inspecting the running
Desktop process's open file descriptors. Desktop's own log recorded
`providerID=scar-vllm modelID=qwen3-coder-30b-a3b` immediately after
launch, with no separate configuration step — it just picked up the config
file `scripts/configure-opencode.sh` had already written for the CLI.

Practical implications:
- One `scripts/configure-opencode.sh` run configures both.
- If Desktop is already running when you (re-)run the script, restart it to
  pick up the change (it doesn't watch the file live, as far as tested).
- `--remove` removes access from both.

## Why tool calling needed to be enabled server-side

OpenCode is an agentic tool — it reads/writes files and runs commands via
tool calls, not just chat. The first live test against this repo's vLLM
server failed immediately:

```
Error: "auto" tool choice requires --enable-auto-tool-choice and --tool-call-parser to be set
```

Both model profiles now set this via `EXTRA_VLLM_ARGS`:

| Profile | Parser | Why this one |
|---|---|---|
| `qwen3-coder-30b-a3b` | `qwen3_xml` | vLLM also ships a `qwen3_coder` parser, but it has a reported bug producing runaway `"!!!!"` output on long inputs containing a tool call. `qwen3_xml` is documented as the more stable choice for Qwen3-Coder specifically. |
| `qwen25-coder-14b` | `hermes` | vLLM's standard tool-call parser for the Qwen2.5-Instruct family. |

**Known rough edge (observed live, not blocking):** the `qwen3_xml` parser
occasionally logs `Error when parsing XML elements: not well-formed
(invalid token)` on some tool-call outputs. It didn't prevent success in
testing here (the request still completed correctly), but if you see
garbled or failed tool calls from OpenCode, check the vLLM container logs
for this — it's a parser-side issue with this specific vLLM
version/checkpoint combination, not something `configure-opencode.sh`
controls.

## Why the provider config sets `limit.context` / `limit.output`

OpenCode has no way to know this server's `--max-model-len` on its own, and
defaults to requesting a large `max_tokens` (observed live: 32000) — which
vLLM rejects outright once it exceeds `max_model_len`:

```
AI_APICallError: max_tokens=32000 cannot be greater than max_model_len=max_total_tokens=16384
```

`configure-opencode.sh` sets the model's `limit.context` to the profile's
`MAX_MODEL_LEN` and `limit.output` to a quarter of that (a reasonable
completion-length cap for coding-agent-style usage, leaving the rest of the
context for the prompt and tool-call history). Without this, every OpenCode
request against this provider fails before reaching the model at all.

## Verifying it works

```bash
opencode models | grep scar-vllm
opencode run --model scar-vllm/qwen3-coder-30b-a3b "say hi in one word"
```

Editing the config file is not sufficient validation — confirm the request
actually reaches vLLM: `docker compose logs vllm` (or `docker logs vllm`)
should show a `POST /v1/chat/completions` line matching the request. This
was verified live end-to-end on `scar.lab`, including a real tool call
(asking OpenCode to read a file and report its contents, and separately to
write a small Python script — both succeeded, tools fired, output was
correct).

## Security note

`options.apiKey` is set to the literal string `local-no-auth-required` — a
placeholder, not a secret. This vLLM server has no authentication (see
README "Security"); OpenCode's schema requires *some* string in that field
for a provider to be usable, even when the backend doesn't check it.

## Behavioral rules (`configure-opencode-rules.sh`)

A local 30B model is noticeably more agentic-by-default and more verbose
than a frontier hosted model — it tends to reach for tools and produce
long, reasoning-heavy responses even for plain questions. `scripts/configure-opencode-rules.sh`
installs a global behavioral policy that pushes back on that: answer
questions directly, don't touch files/tools unless the request needs it,
stay concise, keep implementation changes scoped.

This is a **separate script from `configure-opencode.sh` on purpose**:

| Script | Owns |
|---|---|
| `configure-opencode.sh` | Provider/model wiring (`provider` in `opencode.json(c)`) |
| `configure-opencode-rules.sh` | Behavioral instructions (`AGENTS.md`) |
| OpenCode's own permission system (`permission` in `opencode.json(c)`) | Actual tool authorization/enforcement |

Rules are guidance for the model's judgment, not an enforcement boundary —
a determined or confused model can still ignore them. Anything that must
never happen without approval belongs in `permission`, not in `AGENTS.md`.

### Source of truth and installation

```bash
scripts/configure-opencode-rules.sh            # install/update
scripts/configure-opencode-rules.sh --status    # in sync? (no changes)
scripts/configure-opencode-rules.sh --diff      # show what would change
scripts/configure-opencode-rules.sh --dry-run   # preview an install, touch nothing
scripts/configure-opencode-rules.sh --force     # reinstall even if already current
scripts/configure-opencode-rules.sh --remove    # remove only the managed block
```

`config/opencode/AGENTS.md` in this repo is the canonical copy. The script
installs it into OpenCode's global config directory as `AGENTS.md`
(`~/.config/opencode/AGENTS.md` by default; the script asks
`opencode debug paths` for the real config dir rather than assuming, in
case of a non-default install). Confirmed directly against the installed
OpenCode CLI binary (v1.18.16): `<config-dir>/AGENTS.md` is loaded
automatically as global instructions, in addition to any `AGENTS.md` found
walking up from the working directory to the project root — this isn't an
`instructions:` config setting, it's built-in discovery. CLI and Desktop
read the same config directory (see above), so one install covers both;
restart Desktop to pick up a change if it's already running.

### Managed-block behavior

The script never overwrites the whole global file. It manages only the
region between two markers:

```text
<!-- BEGIN SCAR-VLLM MANAGED RULES -->
...
<!-- END SCAR-VLLM MANAGED RULES -->
```

Anything else already in `~/.config/opencode/AGENTS.md` (personal rules,
project notes) is left untouched. Re-running the script updates only that
block — it never duplicates it — and is a no-op (no backup, no write) when
the installed block already matches the repo. Any existing file is backed
up (`AGENTS.md.bak.<UTC timestamp>`, next to the original) before a
write actually changes it.

`--remove` deletes only the managed block (also backing up first) —
unrelated content in the file survives.

### Updating the rules

Edit `config/opencode/AGENTS.md` in this repo, then re-run the script to
deploy the change. `--diff` shows exactly what would change before you
commit to it.
