---
name: usage-limit
description: Show the current OpenAI Codex rolling usage limits, reset times, plan, and reset-credit count for the account backing Claudex.
disable-model-invocation: true
allowed-tools: Bash(claudex --usage-limit *)
---

The live Codex quota report is below:

```text
!`claudex --usage-limit --no-color`
```

Return that report exactly as shown. Do not call any other tools, reinterpret percentages, or add advice unless the report contains an error.
