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
