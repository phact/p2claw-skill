# p2claw skill

The agent skill for **[p2claw](https://p2claw.com)** — share apps
you've built locally as peer-to-peer URLs that anyone with the link
can open in a browser. Works with any
[Agent Skills](https://agentskills.io)–compatible coding agent.

When you load this skill into your agent and ask it to share an app,
the agent:

1. Detects whether the `p2claw` binary is already on the machine.
2. Installs it if not (via the bundled installer, no `sudo`, no
   global package managers).
3. Starts the daemon — either as a long-running launchd / systemd
   user service, or as a foreground process for short-lived sharing.
4. Registers the route (`name → http://127.0.0.1:<port>`).
5. Hands you back the public URL and a QR code for your phone.

The agent does the work; this skill is the instruction set that tells
it how. Source for the instructions is [`p2claw/SKILL.md`](./p2claw/SKILL.md).

> [!NOTE]
> p2claw assumes a Bash/POSIX shell and supports macOS + Linux.
> Windows users should run their agent inside WSL — the bundled
> installer detects Windows and refuses with a helpful pointer.

---

## Installing the skill

Pick the matching section for your agent. All routes leave you with
the same on-disk shape — a `p2claw/` skill directory the agent can
discover.

### Claude Code

The repo ships a [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json)
manifest, so the cleanest path is to register this repo as a
marketplace and install through it:

```text
/plugin marketplace add phact/p2claw-skill
/plugin install p2claw@p2claw
```

Alternatively, drop the skill in by hand:

```bash
git clone --depth 1 https://github.com/phact/p2claw-skill /tmp/p2claw-skill
cp -r /tmp/p2claw-skill/p2claw ~/.claude/skills/p2claw
```

After install, restart Claude Code and run `/skills` to confirm
`p2claw` appears in the list. (Project-scoped install is the same
flow into `.claude/skills/p2claw/` instead of `~/.claude/skills/`.)

### Claude Desktop

Open the **Customize** panel in the left sidebar → **Skills** → click
the **+** next to *Personal plugins* → paste:

```
phact/p2claw-skill
```

Restart the app once installation finishes. The skill becomes
available as soon as you start a new conversation.

### GitHub CLI (Copilot / `gh skill`)

If you have `gh` v2.90.0 or newer, the GitHub CLI ships a `skill`
subcommand that handles install for any agent it recognises:

```bash
gh skill install phact/p2claw-skill
```

Older `gh`: `gh extension install` the upstream `gh-skill` extension
first, or fall through to the manual git-clone path below.

### OpenAI Codex CLI

Codex scans `.agents/skills/` upward from the working directory, plus
the user-scope skill dir under `~/.config/codex/skills/`. Drop the
skill into either:

```bash
git clone --depth 1 https://github.com/phact/p2claw-skill /tmp/p2claw-skill
mkdir -p ~/.config/codex/skills
cp -r /tmp/p2claw-skill/p2claw ~/.config/codex/skills/p2claw
```

For project-scoped use, replace `~/.config/codex/skills` with
`<repo>/.agents/skills` inside the repo where you want it active.

### GitHub Copilot in VS Code

Skills follow the same SKILL.md format VS Code's Agent Skills feature
expects. Either install via `gh skill install phact/p2claw-skill`
(see above), or use the VS Code skill UI: **Command Palette → Agent
Skills: Add Skill** → paste the repo URL.

### Gemini CLI

```bash
git clone --depth 1 https://github.com/phact/p2claw-skill /tmp/p2claw-skill
cp -r /tmp/p2claw-skill/p2claw ~/.gemini/skills/p2claw
```

(Gemini's path is `~/.gemini/skills/<name>/SKILL.md`. Restart Gemini
CLI to pick up the new skill.)

### OpenCode

OpenCode also reads SKILL.md from a per-user skills directory:

```bash
git clone --depth 1 https://github.com/phact/p2claw-skill /tmp/p2claw-skill
cp -r /tmp/p2claw-skill/p2claw ~/.opencode/skills/p2claw
```

### Any other SKILL.md-compatible agent

The skill folder is `p2claw/` at the root of this repo. Every
SKILL.md-aware agent (per the
[Agent Skills spec](https://agentskills.io)) discovers skills from a
configured directory containing `<name>/SKILL.md`. Drop `p2claw/`
into whatever path your agent uses and you're done.

---

## What gets installed when you use the skill

The skill **doesn't** install the p2claw binary at skill-install time.
The binary is installed lazily, the first time the agent uses the
skill, via the bundled
[`p2claw/scripts/install.sh`](./p2claw/scripts/install.sh) — a
byte-identical copy of the canonical installer at
**[p2claw.com/install](https://p2claw.com/install)**. Drift between
the two is caught by
[`.github/workflows/install-script-sync.yml`](.github/workflows/install-script-sync.yml),
which opens a PR daily if they diverge.

When the agent first runs the bundled installer, it:

- Detects your OS + arch (macOS aarch64/x86_64, Linux x86_64/aarch64).
- Downloads the matching binary from this repo's GitHub releases.
- Verifies SHA-256 against the published `SHA256SUMS`.
- Drops the binary at `~/.local/bin/p2claw` (no `sudo`).
- Optionally registers it as a launchd / systemd `--user` service so
  it survives reboot — only if you say yes when the agent asks.

Everything user-managed: `~/.local/bin/p2claw`, the agent's
`~/Library/Application Support/p2claw/` (macOS) or
`~/.local/share/p2claw/` (Linux) state directory, and the optional
launchd plist or systemd unit. Nothing system-wide.

---

## Uninstalling

```bash
~/.local/bin/p2claw service uninstall   # if you registered as a service
rm ~/.local/bin/p2claw
rm -rf "~/Library/Application Support/p2claw"   # macOS
# or
rm -rf ~/.local/share/p2claw                    # Linux
```

Then remove the skill from your agent's skill directory (the inverse
of whichever install path you used above).

---

## Links

- **Marketing site & docs:** <https://p2claw.com>
- **Install script (canonical):** <https://p2claw.com/install>
- **Skill source:** [`p2claw/SKILL.md`](./p2claw/SKILL.md)
- **Releases (binary):** <https://github.com/phact/p2claw-skill/releases>
- **Agent Skills spec:** <https://agentskills.io>
