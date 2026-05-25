---
name: plannotator-annotate
description: Use when opening Plannotator's annotation UI for a markdown file, converted HTML file, URL, or folder, then responding to the returned annotations.
---

# Plannotator Annotate

Use this skill when the user wants to annotate a document in Plannotator instead of reviewing it inline in chat.

Run:

```bash
plannotator annotate <path-or-url>
```

Behavior:

1. Launch the command with Bash.
2. Wait for the browser review to finish.
3. If annotations are returned, address them directly.
4. If the session closes without feedback, say so briefly and continue.

Do not ask the user to paste a shell command into the chat. Run the command yourself.
