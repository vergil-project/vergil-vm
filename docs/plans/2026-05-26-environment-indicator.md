# Environment Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display the machine hostname in Claude Code's status line so the user can tell at a glance whether they are in the VM or on the host.

**Architecture:** Add a `~/.claude/settings.json` provisioning step to the VM template so every new VM gets a status line showing `hostname -s`. On the host, replace the existing claude-hud status line with the same command. Add an integration test that verifies the settings file is dropped during provisioning.

**Tech Stack:** Lima YAML, JSON, Bash (integration tests)

**Repos:**
- `vergil-vm` at `/Users/pmoore/dev/projects/vergil-project/vergil-vm` (worktree: `.worktrees/issue-38-environment-indicator/`)
- Host `~/.claude/settings.json` (manual, not committed)

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `templates/agent.yaml` | Modify | Add Claude Code settings.json provisioning to user-mode script |
| `tests/test_claude_code.sh` | Create | Verify `~/.claude/settings.json` exists and contains statusLine config |
| `~/.claude/settings.json` | Modify (host, manual) | Replace claude-hud statusLine with `hostname -s`, remove claude-hud plugin entries |

---

## Task 1: Add Claude Code status line provisioning to VM template

**Files:**
- Modify: `templates/agent.yaml:90-113` (user-mode provision script)

- [ ] **Step 1: Add settings.json provisioning to the user-mode script**

Append to the end of the user-mode provision block in `templates/agent.yaml`, after the `.zshrc` heredoc (line 113) and before the `probes:` section:

```yaml
    # Claude Code settings — status line shows hostname for environment awareness
    mkdir -p "$HOME/.claude"
    cat > "$HOME/.claude/settings.json" << 'CLAUDE_SETTINGS'
    {
      "statusLine": {
        "type": "command",
        "command": "hostname -s"
      }
    }
    CLAUDE_SETTINGS
```

This goes inside the existing `- mode: user` provision block's `script: |` section — it is additional shell commands appended to the same script, not a new provision entry.

- [ ] **Step 2: Verify YAML is valid**

Run:

```bash
vrg-container-run -- vrg-validate
```

Expected: validation passes (YAML syntax check, no other errors).

- [ ] **Step 3: Commit**

```bash
vrg-git add templates/agent.yaml
vrg-commit --type feat --scope template --message "add Claude Code status line provisioning for hostname display"
```

---

## Task 2: Add integration test for Claude Code settings

**Files:**
- Create: `tests/test_claude_code.sh`

- [ ] **Step 1: Write the test script**

Create `tests/test_claude_code.sh`:

```bash
#!/bin/bash
# tests/test_claude_code.sh — Verify Claude Code settings are provisioned.
set -euo pipefail

if [ ! -f "$HOME/.claude/settings.json" ]; then
    echo "MISSING: ~/.claude/settings.json"
    exit 1
fi

if ! jq -e '.statusLine.command' "$HOME/.claude/settings.json" > /dev/null 2>&1; then
    echo "MISSING: statusLine.command in settings.json"
    exit 1
fi

echo "test_claude_code: all checks passed"
```

- [ ] **Step 2: Make the test executable**

```bash
chmod +x tests/test_claude_code.sh
```

- [ ] **Step 3: Run validation**

```bash
vrg-container-run -- vrg-validate
```

Expected: passes.

- [ ] **Step 4: Commit**

```bash
vrg-git add tests/test_claude_code.sh
vrg-commit --type test --scope claude-code --message "add integration test for Claude Code settings provisioning"
```

---

## Task 3: Remove claude-hud and configure status line on host

This task is manual — it modifies the user's `~/.claude/settings.json`, which is not part of any repository.

- [ ] **Step 1: Remove claude-hud plugin files**

```bash
rm -rf ~/.claude/plugins/claude-hud
rm -rf ~/.claude/plugins/cache/claude-hud
```

- [ ] **Step 2: Update ~/.claude/settings.json**

Replace the `statusLine` block (currently referencing claude-hud) with:

```json
"statusLine": {
  "type": "command",
  "command": "hostname -s"
}
```

Remove `"claude-hud@claude-hud": false` from the `enabledPlugins` object.

Remove the `"claude-hud"` entry from the `extraKnownMarketplaces` object.

The resulting file should look like:

```json
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  },
  "model": "sonnet",
  "statusLine": {
    "type": "command",
    "command": "hostname -s"
  },
  "enabledPlugins": {
    "paad@paad": true,
    "frontend-design@claude-plugins-official": false,
    "vergil@vergil-marketplace": true,
    "superpowers@claude-plugins-official": true,
    "diogenes@diogenes": true
  },
  "extraKnownMarketplaces": {
    "vergil-marketplace": {
      "source": {
        "source": "github",
        "repo": "vergil-project/vergil-claude-plugin"
      }
    },
    "paad": {
      "source": {
        "source": "github",
        "repo": "Ovid/paad"
      }
    },
    "diogenes": {
      "source": {
        "source": "github",
        "repo": "diogenes-project/diogenes"
      }
    }
  },
  "voice": {
    "enabled": true,
    "mode": "hold"
  },
  "skipDangerousModePermissionPrompt": true,
  "verbose": true,
  "voiceEnabled": true
}
```

- [ ] **Step 3: Verify the status line works**

Restart Claude Code. The status line should display the host's short hostname (e.g., `Renegade`).
