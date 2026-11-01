# Optional SessionStart hook

Off by default. Add it to `~/.claude/settings.json` to print the verdict line at the start of every session. It runs `--quick` (about a second) and keeps only the last line.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/skills/vitals/scripts/vitals.sh --quick 2>/dev/null | tail -n 1"
          }
        ]
      }
    ]
  }
}
```

If you installed as a plugin, point `command` at the plugin's `skills/vitals/scripts/vitals.sh` instead.

Merge the `SessionStart` entry into any existing `hooks` object rather than replacing it. A verdict of AMBER or RED is a cue to run `/vitals` for the full report. The hook never blocks the session and never changes anything.
