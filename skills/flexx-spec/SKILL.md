---
name: flexx-spec
description: Spec interview loop. Use when asked to spec or plan a task.
---

# Flexx Spec Interview

Turns a raw idea into a task so complete that a build agent needs nothing beyond it. Works like plan mode: research the codebase, interview Flexx in rounds until confident, draft, confirm, file. Flexx is the product brain; you are the codebase brain. Never guess product decisions.

## When to use

Flexx says "spec this," "plan this feature," "write the issue for," "draft the task," or describes an idea he wants built. Also use when he asks "how would this work" about something that needs implementation.

## 0. Viability memo when the ask is "should we add X"

Not every business idea is a spec request. "Should we add a marketplace", "what do we
need for this", "how do we benefit", "research this" is a decision memo, and the
deliverable is a doc plus phased draft specs, not code.

Order, and it matters:

1. Verdict in the first lines, then the mechanism in plain language (which app changes,
   which one stays untouched).
2. Competitor mechanics from the operator's OWN docs (a vendor hub, a pricing page, an
   API doc), never blog summaries. Secondary sources conflict on fees, payout cycles and
   KYC, so label any blog number as unverified and quote the primary page.
3. The project's own numbers: existing margin bands, payment fee caps, real order values,
   current catalog size. Compute per-order contribution after fees and tax, and state the
   honest comparison to the existing revenue path. A commission usually earns less per
   order than reselling the same item while needing no capital; say both numbers plainly
   instead of selling the upside.
4. A risk register with the control beside each risk, and name the items that need a
   lawyer or accountant rather than code.
5. Phases sized as spec-sized passes, each ending in a draft task file.
6. Close with the 3-5 decisions that actually gate the build, in prose, after the
   mechanism has been explained.

The memo doc lives at the workspace root as `<PROJECT>-MODEL.md`. Specs it produces go to
`.hermes/tasks/` as `status: draft` and stay `draft` until the confirm round; say in the
handover that they are drafts awaiting a go-ahead, never buildable.

## 1. Research before asking

Read the relevant code first. Find which files are involved, what patterns already exist, and what constraints apply. Never ask Flexx something the codebase can answer:

- Existing patterns (how are routes structured? how is auth handled?)
- Technical constraints (framework version, language, dependencies)
- What already exists that overlaps with this idea
- Marketing-vs-code mismatches: claims on landing cards vs what the code actually gates (catch false advertising before it lands in the spec)
- **Fast-moving external facts** (LLM model IDs and pricing, hosted-service tiers, API versions): verify live before they appear in any question or anchor. What Flexx already runs is ground truth: read his Hermes config (`config.yaml`, `providers:` block, keys redacted; `%LOCALAPPDATA%\hermes\config.yaml` on this box), then confirm the current model string and prices against the provider's live docs. Stale anchors from memory get called out as outdated and burn interview trust.

If the idea touches a project like BotWall, pithos, or prxyauth, cd into that repo and read the relevant files silently. Only surface findings if they constrain a product decision.

**Trace the full surface.** Before finalizing the relevant files list, trace every path the user takes to see this feature:

1. Where does the data live? (dict, db, config file)
2. What renders it? (route, template, component)
3. Where does the user discover it? (homepage card, nav link, search index, sitemap)
4. Is discovery dynamic (loops over a dict/query) or hardcoded (manual HTML entries)?

If any discovery surface is hardcoded, add it to the relevant files list. A feature that works at its URL but does not appear on the homepage is incomplete.

**Audit claims vs gates.** For features already advertised (landing page, pricing cards, help guide), diff the marketing copy against what the code actually gates. A feature sold on a cheaper tier but hard-locked higher is a product bug and a forced decision — surface it as an interview question and give it an AC; never file a ladder that leaves the claim false.

**A second-phase spec starts from the shipped schema, not the old draft.** When Flexx says "spec phase 2" of something already built, re-read the live schema and every route the phase touches, then walk the existing draft AC by AC and list what it silently assumes exists. A draft written before the build names columns and queues the build never created (an order accept and dispatch flow whose `accepted_at` and `dispatched_at` were never added), and it misses hardening that shipped code makes obvious: session revocation, an audit table for edits and PII views, upload type sniffing, idempotent state transitions, and a moderation queue when approval work exists. Add a `## Data model additions` section stating ONE migration and naming the next journal number relative to the last applied one, plus a short `## Decisions locked` block so the build agent does not re-litigate auth, fulfilment ownership or money movement. Keep `status: draft` and `depends_on` the phase it extends.

**Never write a reuse clause for code that does not exist yet.** Before an AC says "reuses the manual product form" or "the shared image uploader", grep for the file and the symbol. If it is absent, either describe the contract the AC actually needs or name the missing component as a dependency. A reuse clause aimed at a form that was never built reads fine in review of the diff (the new code does the work) and only surfaces in a spec audit after merge, which forces a spec amendment against an already-shipped branch.

## 2. Interview in rounds

Ask 1-4 questions per round, each with concrete options. Every question gets your recommended answer listed first. **Deliver the round through the `clarify` tool as pickable buttons** - that is the standing expectation ("send the questions as buttons"); never paste an option list into chat prose. One clarify call carries the whole round (up to 5 questions); the recommended option goes first (the UI marks it Recommended and auto-appends an Other row); he answers by tapping. Put concrete anchor values (prices, quotas, counts) inside the choices — FL3XX reacts to numbers far better than abstractions, and the auto-appended 'Other' lets him name his own. Examples:

- "For the payment page, where should it live? I think /dashboard/billing makes sense since it maps to the existing route structure."
- "Should failed payments redirect to a retry page or show a modal? Modal is cleaner but retry page lets them review their payment info."

**Anchor number questions.** For anything numeric (prices, caps, quotas), never ask cold — offer 2-3 concrete anchor sets with the recommended one first and let him react or give his own. He edits an anchor or hybrids two options, so anchors beat open questions for numbers.

**A clarify round can come back half answered.** The form closes on a timeout; he may tap the one decision he cares about and leave the rest. Resend ONLY the unanswered questions, state the already-answered ones as fixed in one line, and never restart the whole round or quietly fill the gaps with your recommended defaults. "Resend the questions" means exactly this, not that the round failed.

**Never batch a dependent question with the question that decides whether it applies.** A clarify call renders every question at once, so a conditional follow-up still gets answered after the gate answer deleted its premise (a POD-scope and POD-fraud-control pair came back as "no pay on delivery" plus a picked fraud-control option). Ask the gate in its own round and fire the follow-ups only if it survives. When an answer rejects the premise instead of picking an option, treat it as a decision to cut the feature: discard the dependent answers, give the cut its own NG id, and say so in the draft ("POD is out, recorded as NG-1") rather than quietly keeping the feature under softer wording. Answer text often arrives voice-dictated and ungrammatical; read intent, and never quote his phrasing into an AC.

**Agent features get a hardening block in the FIRST draft.** When the feature is an LLM agent (chat assistant, tool-calling bot), do not wait to be asked for security: include the injection-gating criteria up front — trust boundary + scope lock as non-editable code constants, a strict tool registry (no tool takes a user/tenant id; out-of-schema args refused at call time; unknown tool = hallucination error), tool results labeled as untrusted data, an iteration cap with a tools-disabled forced final, a server-side reply sanitizer, a canary marker, and a red-team battery as its own AC (run with the real model at acceptance). Flexx demanded exactly this the moment a draft landed without it; MineRich's `src/agent/` is the reference implementation to port.

**Storefront specs order IN-APP, always.** For e-commerce specs the app is the
only ordering surface: cart, checkout, payment provider. WhatsApp is a support
channel only (contact page, footer, mobile menu) plus internal supplier-side
order forwarding. Never write a WhatsApp-order CTA, a "complete it on WhatsApp"
checkout fallback, or any buyer-facing route around the app for ordering; Flexx
flags these immediately when they surface in the UI.

Ask only genuine product decisions:

- Behavior forks: who sees it, what exactly happens, where does it live
- Scope boundaries: what is explicitly OUT of this issue
- Edge cases that change acceptance criteria: empty states, what happens on error, permission boundaries
- Data implications: existing records, migrations, API fields

After each round, fold the answers in and test:

> Could two different engineers read this spec and ship the same observable behavior?

If any ambiguity remains, ask another round. There is NO cap on rounds. A small fix might need two questions; a complex feature legitimately needs 10+. Never stop early because it feels like a lot of questions.

Once the test passes, stop. No filler questions.

## 3. Draft the spec

Use exactly this shape in the output:

```yaml
---
slug: <kebab-case-slug>
status: draft
depends_on: []
created: <ISO date>
claimed_at: <set by build agent when locking>
priority: normal
---
```
## Problem
[One or two sentences on what user/business problem this solves]

## Acceptance Criteria
- [ ] AC-1 - Observable, testable outcome one. Use Flexx's language.
- [ ] AC-2 - Observable, testable outcome two.
- [ ] AC-3 - ...

## Non-goals
- NG-1: What must NOT change in this task
- NG-2: What is explicitly excluded or saved for later

## Relevant files
- path/to/file.ts - why it matters

## How to verify
1. Numbered manual steps anyone can follow. Cover every AC.
```

Rules for the draft:

- Every acceptance criterion is an observable outcome. Every non-goal has a stable id.
- AC-N and NG-N IDs are the contract that build/review skills enforce. Do not change them after filing.
- No AC may require a non-goal. If one does, ask another round to resolve it.
- Each issue is one day of agent work or less. Bigger ideas become a chain of small issues. Order them so each is buildable from merged code of the prior ones. If Flexx explicitly chooses to keep a bigger scope in one spec, honor it and state the size in the draft instead of splitting against his wish.
- When he asks to spec several items at once ("spec 1 to 3") and one of them exceeds a day, split that item into a second descriptive slug with `depends_on` pointing at the first, and state the split in one line in chat. Do not silently inflate one spec to cover it, and do not stop to ask permission for the split.
- **A requirement added mid-batch gets its own slug and its own confirm.** When Flexx appends scope while other specs are still drafts ("before you proceed, also..."), research and interview the addition separately, file it as a new task, and show the new draft for a go-ahead. Never fold unreviewed scope into an already-confirmed spec, and never file it without the confirm round.
- Copy every number the interview settled (prices, quotas, caps, counts) VERBATIM from the answer into the AC — never re-derive, round, or paraphrase a number. Drift between the interview and the draft file is invisible until the build; when it surfaces the build agent must ask and the file gets re-fixed anyway, so get it exact the first time.
- The frontmatter is the task schema. `slug` must match the filename. `status` starts as `draft`. `depends_on` lists slugs of tasks that must be merged before this one can be built. Leave empty if no dependencies.

## 4. Confirm

Show the draft in chat and get Flexx's go-ahead. Wait for confirmation before writing anything to disk.

With the draft, list the few consequential defaults as explicit veto flags (what existing paid users get under new rules, price math, features whose advertised claim changes) — one line each. Flags he can veto now are cheaper than AC rewrites later.

## 5. Write to disk

Write the final spec to `.hermes/tasks/<slug>.md` in the project directory (if it's a specific project). Use the task title as the slug.

For generic/non-project tasks, write to `~/.hermes/tasks/<slug>.md`.

Also save as a TODO for the current session.

**Lint the file before showing it.** `python scripts/loop-lint.py .hermes/tasks` (from a repo that
carries the loop tooling) enforces the shape above mechanically: slug equals the filename,
sequential AC/NG ids, no AC referencing an NG, the five required sections, `status: draft` with
no `claimed_at`. A spec that fails it is not buildable, and the failure is cheaper to read than
to argue about in review. Exit 1 means contract errors, exit 2 means the linter could not run.

## Hard rules

- Never apply the `agent-ready` label on your own initiative, and never as a way to move a draft
  forward. It flips only at the section-6 gate, on his tap, or when he reactivates a blocked
  task per section 7. The decision is his; the keystroke is yours only after it.
- Never start building during the spec interview.
- Never guess product decisions - ask.
- Output the final spec in a copyable code block so Flexx can paste it into Linear/GitHub issues.

## 6. Human gate: from draft to the build queue

The label stays `draft` until Flexx says otherwise. The agent never self-promotes a spec, and
never starts building during or after the interview.

Once he has the draft in chat and approves it, offer the gate as a `clarify` call so he does
not edit frontmatter by hand:

- question: "Spec `<slug>` is written. Put it in the build queue?"
- choices: ["Mark agent-ready", "Keep as draft", "Needs another round"]

"Mark agent-ready" is Flexx deciding, not the agent: flip `status: draft` to `status: agent-ready`,
commit `ready: <slug>`, and push. With the post-commit hook installed (see README) the build
dispatcher fires on its own; without it, ask "Work the queue now?" and run the build one-shot
from `flexx-build` step 7 only on a tap.

"Keep as draft" ends the pass. "Needs another round" returns to step 2.

## 7. Answering a blocked question

When a task is `status: blocked` and Flexx answers the question in chat:

1. Append a `## Resolution` section to the task file with Flexx's answer.
2. Flip `status` back to `agent-ready`.
3. Tell Flexx the task is back in the queue.

This is manual and explicit. The agent does not infer intent from casual chat replies. Flexx must clearly answer the blocked question before the agent reactivates the task.