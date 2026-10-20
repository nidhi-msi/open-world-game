# Agent Workflow Rules (owner: nidhi-msi)

These rules govern EVERY work session in this project. They were set by the project
owner and must be followed in strict order.

## 1. Test before reporting — always
- After implementing any feature or fix, the agent MUST test it before claiming success.
- Minimum test: headless Godot run of the main scene (portable 4.3 exe,
  `--quit-after 150`) and report: exit code, SCRIPT ERROR count, animation/scene errors.
- If ANY error appears: fix it and re-test. Only a fully clean run may move to step 2.

## 2. Ask permission — one step at a time
After a clean test, the agent must ask the owner for permission **one by one** and
wait for an explicit yes after EACH step before doing it:

1. **Doc update** — "May I update AGENT_LOG.md?" (append the feature section:
   ✅ What Was Done / ⚠️ Problems & Bugs Encountered / 🔧 How It Was Solved)
2. **Git commit** — "May I commit?" (stage + commit, message: `Phase X: <feature> — <short summary>`)
3. **Git push** — "May I push?" (push to `origin main`)

## 3. Wait at the gate
- The agent must NOT start the next feature/phase until all three steps are approved
  and completed AND the owner gives explicit permission to move forward.
- If the owner reports a bug instead: fix first, re-test, then restart the permission
  loop from step 2.

## Git facts (fixed)
- Owner GitHub account: **nidhi-msi** · email: **nidhiqls@gmail.com**
- Branch: **main** · Remote: **origin** (owner's GitHub repo)
- Never commit: `.godot/` (regenerated cache — see `.gitignore`)
- GitHub hard limit: no single file above 100 MB — check before committing new assets
