# fleXX-loop

A three-skill dev loop for Hermes Agent: **spec -> build -> review**.

Each skill is a self-contained SKILL.md that plugs into Hermes Agent's skill system. Together they form an autonomous development loop where:

1. **flexx-spec** interviews you about a raw idea until the spec is unambiguous, then files a build-ready task
2. **flexx-build** picks up the next ready task, implements every acceptance criterion, pushes a branch
3. **flexx-review** audits the branch against its spec, posts a structured verdict

You stay the gatekeeper. No skill ever merges.

## The contract system

Every task has:
- **AC-N** (Acceptance Criteria) - observable, testable outcomes
- **NG-N** (Non-goals) - what must NOT change

These IDs flow through all three skills. Spec writes them, build implements them, review checks them. Once filed, IDs never change.

## Task schema

```yaml
---
slug: <kebab-case-slug>
status: draft | agent-ready | in-progress | built | blocked | merged
depends_on: []
created: <ISO date>
---
```

## Task states

| State | Meaning |
|---|---|
| `draft` | Spec written, not yet approved for build |
| `agent-ready` | Flexx marked it ready for the build loop |
| `in-progress` | Build agent claimed it (lock) |
| `built` | Build pushed the branch, awaiting review/merge |
| `blocked` | Build hit an ambiguity, waiting on Flexx |
| `merged` | Merged to default branch |

## Installation

Copy the three skill directories into your Hermes skills folder:

```bash
cp -r skills/flexx-spec ~/.hermes/skills/software-development/
cp -r skills/flexx-build ~/.hermes/skills/software-development/
cp -r skills/flexx-review ~/.hermes/skills/software-development/
```

Or install via the Hermes skill management tool:

```
skill_manage(action='create', name='flexx-spec', content=<SKILL.md content>, category='software-development')
skill_manage(action='create', name='flexx-build', content=<SKILL.md content>, category='software-development')
skill_manage(action='create', name='flexx-review', content=<SKILL.md content>, category='software-development')
```

## How to use

### Manual

1. Tell your agent "spec this" and describe your idea -> agent interviews you, drafts the spec, you confirm, it files the task
2. Mark the task `status: agent-ready` in frontmatter
3. Tell your agent "work the queue" -> agent picks the task, builds it, pushes a branch
4. Tell your agent "review this" -> agent audits the branch, posts the verdict
5. You merge

### Event-driven (git hooks, fully local, no VPS)

The loop can run fully autonomously on your local machine using git hooks. No VPS, no gateway, no network dependency.

**Setup:**

```bash
# Install hooks into any repo where you use fleXX-loop
bash scripts/setup-hooks.sh /path/to/your/repo
```

This installs a `post-commit` hook that detects when a task file flips to `status: agent-ready` and automatically triggers the build agent via `hermes chat -q`.

After build pushes the branch, it automatically fires review as a background one-shot.

**Flow:**

```
You commit task with status: agent-ready
    ↓ (post-commit hook fires instantly)
hermes chat -q triggers flexx-build
    ↓ (build implements, pushes branch)
hermes chat -q triggers flexx-review
    ↓ (review audits, posts verdict to chat)
You see the verdict, you merge
```

You never type "work the queue" or "review this". The loop is reactive.

### Cron (polling, for unattended machines)

Set up two cron jobs (spec is interactive only, never cron):
- **Build**: runs every N hours, picks the next `agent-ready` task, builds it, reports back
- **Review**: runs after build, reviews unmerged branches, posts verdicts

## Design principles

- **Human is the merge button.** No skill ever merges or enables auto-merge.
- **Contract first.** AC-N and NG-N IDs are immutable once filed.
- **One task per pass.** Each cron run does one thing and exits.
- **Never guess.** If something is ambiguous, the skill blocks and asks.
- **Scope is binding.** Build only touches ACs. Review flags anything beyond them.

## Requirements

- Hermes Agent (or any agent system that supports SKILL.md skills)
- Git
- `gh` CLI (optional, for branch detection)

## License

MIT