# How the system writes in a tracker

<!-- The standard for issues and comments the system creates on GitHub — in its own
     backlog and in a project's backlog. This is not a form to fill in: the rules
     apply to every issue created and every comment written. Why the file exists:
     without a standard every agent sets the tone anew, and a tracker drifts from a
     working document into a retelling of one's own merits. -->

Trackers are read by outsiders: colleagues, future contributors, a chance visitor to
a public repository. An issue in one is a working document, not a message to the
owner and not a report of work done.

## What an issue contains

| Part | Content |
|---|---|
| Title | the component and the fact: what does not work, or what needs doing. One line, no emoji, no moral drawn at the end |
| What happens | observable behaviour: date, place in the code, numbers, the error text |
| Why it is a defect | the consequence, not an assessment |
| What to do | concrete changes, numbered |
| Context | where and when it was found, how it was verified |

The closing comment says what changed and how it was verified, with a link to the
commit. Not a retelling of the road to the solution.

## Tone

- **Third person and facts.** Not "I found", "I suggest", "I am leaving the issue
  open", but "found", "proposed", "the issue stays open".
- **The owner is one of the readers, not the addressee.** "your fixes", "good news"
  and the like are not used in a tracker: whatever is needed from the owner is
  written as a requirement of the issue.
- **No assessment of one's own work.** "acceptance has teeth", "it came out better
  than intended", "rules bought at a high price" — remove them. That a mechanism
  works is shown by the description of how it was verified, not by an adjective.
- **No aphorism in place of an argument.** "Otherwise it is not a plan but a hope"
  is replaced by what was meant: "a plan with no way back cannot be verified".
- **No wording longer than the fact.** If a sentence can be shortened without
  losing a checkable claim — shorten it.

## What never goes into a tracker

The rule holds regardless of the repository's visibility: visibility changes, and
the edit history stays available. Blanking an issue body after the fact does not
help.

1. **Verbatim quotes from conversations with the owner.** Paraphrasing the meaning
   is fine; copying the message is not.
2. **Names of personal and work infrastructure**: servers, networks, neighbouring
   projects, other people's repositories. A run is named neutrally ("the pilot
   project"), machines by role ("the home server", "the working machine"). The list
   of forbidden names is the same one used for the core-purity check:
   `~/.claude/forge/private-names.txt`.
3. **Personal data and descriptions of what it consists of.** "a file with personal
   data" is enough to state an issue; listing which fields and about how many people
   is not needed.
4. **Secrets and internal addresses** — including the ones that are "no longer valid
   anyway".

## A security finding

Before creating an issue the repository's visibility is checked (`gh repo view`
requesting the `visibility` field). A public repository with an open vulnerability →
a private security advisory through the API, and a neutral line in the tracker with
no recipe for reproducing it.
