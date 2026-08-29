<!-- telegram-protocol.md — what the system writes to the owner, and when, while it builds on its own. Read by forge-build; the templates are filled in by substituting {{...}}. The channel is transport only: the truth about questions always lives in questions.md, never in the conversation. -->

# Protocol of messages to the owner

The owner is not sitting next to the build. So there must be few messages, each one
self-contained (understandable from a phone, without opening the repository), and
none of them may require working out what is going on in the first place.

## When what gets sent

| Type | Trigger | Size |
|---|---|---|
| ❓ Question | A fork that cannot be settled with a sensible default | context ≤ 3 lines + options |
| ✅ Block done | A block is accepted: tests green, smoke passed | ≤ 5 lines |
| ⚠️ Alert | The build is stuck, hit a limit, or the environment broke | ≤ 5 lines |
| 🏁 MVP ready | The finish: the product is running and verified | link + summary |
| 👀 Look | An accepted block changed what a person sees: a screen, human-facing text, the order of work | 1–3 screenshots + one sentence |

## The "look" message: why it exists at all

A measurement of 61 defects that got past the tests isolated a class of 13% that
**no** mechanism of the system catches: confusing onboarding, two rows of identical
buttons, a missing accessibility hint, docs and locales that drifted away from the
product. A test checks a claim someone formulated in advance — and nobody
formulates these, because they are **visible and only visible**. A spec review walks
a scenario, and the scenario walks: the path works, the result is reached, and the
product is still awkward or self-contradictory.

So "look" is not a report with a picture; it is the only mechanism for that class.
Hence three requirements:

- **cheap for the owner** — glance and say one sentence; not read a report, not walk
  a scenario;
- **shows the product, not a description** — a screenshot, not a file path and not a
  list of changes: the point is to see it from a phone without opening anything;
- **does not block the build** — sent and move on; the answer is picked up at the
  next acceptance, like any other answer from the owner.

## Rules for sending

- **Questions go in batches, not one at a time.** Open questions accumulate and go
  out as a single message when the current background agent finishes. Five separate
  notifications in a row is not "responsive", it is a reason to turn the bot off.
- **A question is sent once.** A sent question is marked in `questions.md` as
  already gone; the system sends no reminders — the owner's silence is not an error,
  the question is simply waiting.
- **`telegram: off` in the profile — nothing is sent at all.** The question is still
  written into `questions.md`, and the build continues under the rule "only the
  dependent tasks are blocked". A missing channel is no reason to stop.
- **The channel is transport; the truth is in the files.** If a message was not
  delivered, the state of the build does not change: `questions.md`, `decisions.md`
  and `progress.md` stay complete without the conversation.
- **Sending is an HTTP call to the channel.** The channel is a standing service on
  the owner's machine, not a tool inside a session. The address and the secret live
  in the personal profile: `~/.claude/forge/channel.env` (`CHANNEL_URL`,
  `FORGE_SECRET`). Sending:

  ```bash
  curl -s -X POST "$CHANNEL_URL/notify" \
    -H "Authorization: Bearer $FORGE_SECRET" -H 'content-type: application/json' \
    -d '{"project":"<name>","kind":"question|block|alert|done|show","text":"<text>"}'
  ```

  Whom to send to, the channel knows by itself — the allow-list is its business, not
  the system's. **A `2xx` response is the only proof of sending:** `502` means
  Telegram refused, and such a question counts as not sent.
- **The project name is the repository directory's name**, and it is identical in
  all three calls (`notify`, `inbox`, `ack`):

  ```bash
  project="$(basename "$(git rev-parse --show-toplevel)")"
  ```

  Taken exactly this way rather than from the documents: the name must be available
  in any session without reading the spec, and must not depend on what the project
  was called in prose. A name that drifts breaks addressing silently — the question
  goes out under one name and the answer is looked for under another, and the build
  waits for an answer that is lying right there.
- **The format is plain text.** A markup mode requires escaping special characters,
  and one unescaped character kills the whole send. For service notifications the
  markup is not worth it.
- **The owner's answers are fetched on demand**, they do not arrive in the session:
  `GET $CHANNEL_URL/inbox?project=<name>` returns what is unprocessed and addressed
  to this project, `POST $CHANNEL_URL/ack` with `{"ids":[…],"project":"<name>"}`
  marks it processed. Mark it **after** the answer has been applied: otherwise a
  crash between "read it" and "applied it" eats the answer silently.

  ```bash
  curl -s "$CHANNEL_URL/inbox?project=$project" -H "Authorization: Bearer $FORGE_SECRET"
  curl -s -X POST "$CHANNEL_URL/ack" \
    -H "Authorization: Bearer $FORGE_SECRET" -H 'content-type: application/json' \
    -d "{\"ids\":[12],\"project\":\"$project\"}"
  ```

  "On demand" means the skill itself must create the demand: the channel wakes
  nobody and never reminds anyone of itself. That is why fetching is tied to the
  places where work stops anyway — accepting a block and returning to the state
  files (`forge-build`, step 4). Without that tie the inbox is never fetched: no
  occasion arises. Verified on the run of 13.08.2026 — an answer from the owner lay
  in the channel for five days with a healthy channel and a running build.
- **If the channel does not answer — say so immediately, not silently.** The
  liveness check is `GET $CHANNEL_URL/healthz` without the secret; it returns `503`
  if the Telegram polling has been knocked out or the database is not answering, and
  it shows when the last successful fetch happened. Channel unreachable → a warning
  in the terminal that questions will only be in `questions.md`, and the build goes
  on. Unnoticed absence of notifications is the worst possible outcome: the owner
  thinks things are moving while the system stands with a question.

## Addressing answers: one queue for all builds

The channel's answer queue is shared. With one project being built that goes
unnoticed; as soon as there are two, the question arises whose answer is taken by
whoever asks first.

- **An answer is addressed by replying.** The owner replies to a channel message —
  the channel finds in its outbound log, by message id, whose question it was, and
  marks the answer with that project. That is why for `question` and `alert` the
  channel itself appends a line asking for a reply.
- **`GET /inbox?project=<name>` returns only what is yours** — your answers and the
  unaddressed ones. Without the parameter everything is returned: an old client keeps
  working, but also takes what is not its own, as before. Using the parameter is
  mandatory.
- **`POST /ack` with `project` will not mark what is not yours.** Foreign ids come
  back in the `rejected` field with status `409`; yours are marked all the same.
  `409` is not a reason to retry: it says that some answers are addressed elsewhere.
- **An answer that is not a reply has no address** and is visible to every build.
  Reaching the wrong build is bad, but reaching nobody is worse: an unaddressed
  answer would otherwise simply vanish. The channel says exactly that in its
  confirmation to the owner — that it could not tell who it was for.
- **Do not apply someone else's answer even when you can see it.** An unaddressed
  answer that clearly concerns another project stays in the queue, unprocessed.

Verified in the review of 26.08.2026: before this addressing existed, whichever
dispatcher asked first took someone else's answer, applied it to its own questions
and marked it processed — the second project waited forever, the first went the
wrong way, and both stayed silent.

## Templates

### 👀 Look

```
👀 Take a look · {{project}}

{{what appeared or changed — one sentence, in the product's language}}

If something looks wrong — reply with one sentence.
```

Screenshots go in the `photos` field (base64, up to 10, up to 5 MB each); the
caption is attached to the first picture. **Look messages accumulate and go in a
batch**, like questions: one per accepted block turns into a stream that people stop
opening — which is exactly the outcome the mechanism exists to prevent.

### ❓ Question (batched)

```
❓ Your decision needed ({{count}})

{{number}}. {{the question in one sentence}}
   Context: {{why this is a fork, 1–3 lines}}
   1) {{option 1}}
   2) {{option 2}}
   Recommended: {{option number}} — {{why}}
   Blocks: {{task ids, or "nothing, work continues"}}

You can answer with a number, in your own words, or "decide for me".
```

A recommendation is mandatory whenever one is possible at all: the answer "decide
for me" must be executable straight away, not turn into another round of questions.

### ✅ Block done

```
✅ Block "{{block name}}" is done

Done: {{what appeared, in one sentence}}
Verified: {{which smoke passed — the actual command or scenario}}
Next: {{which blocks started after it, or "waiting for an answer to {{question id}}"}}
```

### ⚠️ Alert

```
⚠️ {{what happened}}

Cause: {{briefly, no stack traces}}
Doing now: {{continuing with other tasks / rolling back / the build has stopped and is waiting for you}}
Needed from you: {{a concrete action, or "nothing, I will carry on"}}
```

An alert without the last line is useless: from the message alone the owner must
understand whether anything is required of them right now.

"The build has stopped and is waiting for you" is written **only** that plainly.
Phrasing like "paused, will resume automatically" used to stand here and it lied:
there was nothing that could bring the build back, and the owner, having read about
automatic resumption, calmly waited several hours for something that could not
happen by itself.

### 🏁 MVP ready

```
🏁 {{project name}} — the MVP is ready

Open: {{link}}
Demo access: {{demo-mode credentials or "no sign-in"}}
Spec review: {{the converge result — how many iterations, what diverges}}
Known discrepancies: {{list or "none"}}
```

## The owner's answers

- An answer is free text, an option number, or "decide for me".
- **"Decide for me"** → the system makes the decision, writes it into
  `decisions.md` marked "decided autonomously", and unblocks the dependent tasks.
  Such a decision is shown to the owner in the build status summary — they learn of
  it even if they forgot the question.
- The answer is transferred into `questions.md` (status `answered`) before any work
  based on it begins: if the session dies right after the answer, the answer is not
  lost.

## Once, before the first build

The channel is a **standing service**: it is brought up once on the owner's machine
and lives there. Nothing needs switching on inside Claude Code sessions; deployment
and verification are described in `channel/README.md` of the system's repository.

1. **Bring the channel up** and check it **from the working machine**, not from the
   machine hosting it: `GET $CHANNEL_URL/healthz` must return `200`. An answer from
   inside the host proves nothing — the port may be closed precisely from outside.
2. **Put the address and the secret into the personal profile** —
   `~/.claude/forge/channel.env` (`CHANNEL_URL`, `FORGE_SECRET`), permissions `600`.
   None of this goes into the repository.
3. **`telegram: on` in the profile** — otherwise the system deliberately sends
   nothing (see the rules above).
4. **The Telegram plugin in Claude Code must be OFF**
   (`enabledPlugins` in `~/.claude/settings.json`). This is not a matter of taste but
   a hard requirement: the plugin raises a **second** listener for the same bot, and
   Telegram allows one. The second knocks out the first with a `409`, and **the one
   knocked out does not crash — it silently stops receiving messages** while the bot
   still looks alive. Verified on the live channel: receiving was down for twelve
   minutes while the plugin was running.

   A separate trap that makes this easy to miss: the plugin is switched on by a
   **setting, not a launch flag**. That is, it comes up by itself in every session,
   and "restart the session without the flag" does not help — only switching it off
   in the settings does.
