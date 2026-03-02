# OpenCode Configuration

Configuration for OpenCode AI coding agent with local vLLM backend.

## What is OpenCode

OpenCode is an open source AI coding agent available as a terminal interface, desktop app, or IDE extension. It analyzes codebases and assists with coding tasks through an interactive chat interface.

## Installation

```bash
curl -fsSL https://opencode.ai/install | bash
```

Alternative installation methods:
- **npm**: `npm install -g opencode`
- **Homebrew**: `brew install opencode`
- **Docker**: Available on Docker Hub

Prerequisites:
- Modern terminal emulator (WezTerm, Alacritty, Ghostty, or Kitty)
- API keys for LLM providers (or local vLLM setup as configured here)

## Our Configuration

This setup uses a local vLLM server with Devstral model:

- **Provider**: vLLM via OpenAI-compatible API
- **Model**: `mistralai/Devstral-Small-2-24B-Instruct-2512`
- **Endpoint**: `http://192.168.62.138:9000/v1`

### Hooks

The configuration includes experimental hooks:
- **file_edited**: Runs Prettier on edited JSON files
- **session_completed**: Touch marker file on session completion

### Custom Agents

- **review**: Reviews code for best practices and potential issues

## Usage

Copy `opencode.json` to your project root, then run:

```bash
opencode
```

### Key Commands

- `/init` - Analyze project and generate AGENTS.md
- `/connect` - Configure LLM provider
- `/share` - Share conversation with team
- `Tab` - Toggle Plan mode (suggests without changing)
- Undo/Redo - Revert or restore changes

## Custom Commands

The `commands/` directory contains custom slash commands adapted for OpenCode.

### Available Commands

| Command | Description |
|---------|-------------|
| `/cc-pn` | Generate implementation plan from research |
| `/ce-cm` | Context compact for token limit management |
| `/ce-ex` | Execute plan with gated checks and logging |

### Installing Commands

OpenCode looks for commands in two locations:

**Per-project** (recommended for team sharing):
```bash
mkdir -p .opencode/command
cp commands/*.md .opencode/command/
```

**Global** (available in all projects):
```bash
mkdir -p ~/.config/opencode/command
cp commands/*.md ~/.config/opencode/command/
```

### Command File Format

Each command is a markdown file where the filename becomes the command name:
- `cc-pn.md` -> `/cc-pn`
- `ce-ex.md` -> `/ce-ex`

**Frontmatter options:**

```yaml
---
description: Brief description shown in UI
agent: optional-agent-name      # Which agent runs this
model: optional-model-id        # Override default model
subtask: true                   # Force subagent invocation
---
```

**Special syntax in prompts:**

| Syntax | Purpose | Example |
|--------|---------|---------|
| `$ARGUMENTS` | All args passed to command | `/cc-pn my-feature` |
| `$1`, `$2` | Positional arguments | First arg, second arg |
| `` !`cmd` `` | Inject shell output | `` !`git status` `` |
| `@path` | Include file content | `@src/main.ts` |

### Configuring via JSON

Commands can also be defined in `opencode.json`:

```json
{
  "command": {
    "cc-pn": {
      "template": "Generate plan for: $ARGUMENTS",
      "description": "Generate implementation plan"
    }
  }
}
```

### Workflow

These commands support a context engineering workflow:

1. **Research** - Gather requirements (manual)
2. **Plan** (`/cc-pn`) - Create implementation plan
3. **Execute** (`/ce-ex`) - Implement with validation
4. **Compact** (`/ce-cm`) - Preserve context when needed

## Documentation

- Full documentation: https://opencode.ai/docs
- Commands reference: https://opencode.ai/docs/commands/
- Configuration: https://opencode.ai/docs/configuration/
