# Environment Indicator Design

**Issue:** [#38 — Visual indicator in Claude Code to distinguish VM from host](https://github.com/vergil-project/vergil-vm/issues/38)

**Date:** 2026-05-26

## Problem

When running Claude Code inside the VM, there is no visual distinction from
running on the host. The shell prompt already shows the hostname (`lima-vergil-agent`
vs `Renegade`), but Claude Code's status line does not — making it easy to lose
track of which environment you are operating in.

The status line slot is currently occupied by claude-hud, an untuned third-party
plugin that adds unnecessary complexity.

## Design

Replace claude-hud with a minimal status line command that displays the hostname.
This provides an at-a-glance indicator of the current environment without
introducing any new configuration surface.

### How it works

Claude Code's `statusLine` setting in `settings.json` runs a shell command and
displays its output. The command reads the machine hostname:

- **VM:** displays `lima-vergil-agent` (or `lima-vergil`, depending on the
  instance name)
- **Host:** displays `Renegade` (or whatever the macOS hostname is)

No environment variables, marker files, or runtime detection logic is needed.
The hostname is inherently different between environments.

### Status line command

The status line receives a JSON object on stdin with session metadata (model,
token usage, etc.). The command outputs the short hostname:

```bash
hostname -s
```

### Changes

#### 1. Uninstall claude-hud (host)

Remove claude-hud from the host's `~/.claude/settings.json`:

- Delete the `statusLine` block that references claude-hud
- Remove the `"claude-hud@claude-hud"` entry from `enabledPlugins`
- Uninstall the plugin via Claude Code's plugin management (or manually
  remove `~/.claude/plugins/claude-hud/` and its cache entry under
  `~/.claude/plugins/cache/`)

#### 2. Configure status line on host

Add the new status line command to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "hostname -s"
  }
}
```

#### 3. VM provisioning (`agent.yaml`)

Add a step to the user-mode provision script that drops a
`~/.claude/settings.json` with the status line config. This ensures every
new VM gets the indicator automatically, with no manual setup.

```yaml
- mode: user
  script: |
    # ... existing provisioning ...

    # Claude Code status line — show hostname for environment awareness
    mkdir -p "$HOME/.claude"
    cat > "$HOME/.claude/settings.json" << 'SETTINGS'
    {
      "statusLine": {
        "type": "command",
        "command": "hostname -s"
      }
    }
    SETTINGS
```

### Scope boundaries

- **In scope:** status line configuration for VM and host, claude-hud removal.
- **Out of scope:** zsh prompt changes (the existing prompt already shows the
  hostname), color/theming, terminal title manipulation.

### Graceful degradation

If Claude Code does not support the `statusLine` setting (e.g., an older
version), the config key is silently ignored. The shell prompt still shows
the hostname as it always has.

## Repositories affected

| Repository | Change |
|---|---|
| vergil-vm | Add `~/.claude/settings.json` provisioning to `agent.yaml` |
| (host setup) | Manual: update `~/.claude/settings.json`, remove claude-hud |
