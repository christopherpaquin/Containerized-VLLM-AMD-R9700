/**
 * OpenCode Compaction Recovery Plugin
 *
 * Customizes OpenCode context compaction to prioritize concrete operational
 * state (files modified, active task, test status, blockers, next action)
 * over conversational history and repeated planning.
 *
 * Placed in <config_dir>/plugins/ to be automatically discovered by OpenCode.
 */

export default async () => {
  return {
    "experimental.session.compacting": async (_input, output) => {
      output.prompt = `Output an operational state summary in exactly the Markdown structure shown inside <template> so an execution-oriented coding agent can immediately resume implementation without discovering or restating the project. Do not include the <template> tags in your response.

<template>
## CURRENT OBJECTIVE
- [one brief sentence describing the overall goal]

## CURRENT TASK
- [the exact specific task being executed right now]

## COMPLETED WORK
- [concrete tasks finished, verified facts, or implemented features; otherwise "(none)"]

## FILES MODIFIED
- [file paths modified and what was changed in each; otherwise "(none)"]

## FILES CURRENTLY BEING WORKED ON
- [file paths under active modification or inspection; otherwise "(none)"]

## TESTS RUN & RESULTS
- [exact test commands run and whether they passed/failed; otherwise "(none)"]

## KNOWN FAILURES & BLOCKERS
- [failing commands, error messages, or blockers preventing progress; otherwise "(none)"]

## IMPORTANT USER CONSTRAINTS
- [user constraints, non-negotiable rules, specific directives; otherwise "(none)"]

## NEXT ACTION
1. [immediate concrete next action to take]

## DO NOT REPEAT
- [actions, file reads, or tests already completed that must not be repeated]
</template>

Compaction Rules:
- Prioritize concrete operational state over conversational history.
- Preserve exact file paths, symbol names, shell commands, test results, and error messages.
- Preserve unfinished work and failing states.
- Remove conversational filler, apologies, and repeated planning.
- Remove obsolete command and file outputs.
- Distinguish completed work from proposed work.
- Clearly identify the single most likely next action so the agent can resume immediately.`;
    },
  };
};
