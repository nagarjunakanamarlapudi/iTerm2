# LinkedIn Posts — Netra Launch

## Post 1: Permission-Miss Story (post FIRST)

> Attach image: `01-sidebar-claude-code.png` (upload natively)
> Put the Medium link as FIRST COMMENT, not in the post body

```
Claude asked permission in 3 tabs.
I didn't notice for 3 hours.

I was deep in a refactor — flow state, forgot to eat.
Claude was rewriting my auth module in tab 3
while I worked alongside it in tab 7.

Three hours later I started clicking through my other tabs.

Tab 11: Claude wanted to modify a production config. Waiting.
Tab 5: Claude needed to delete a database migration. Waiting.
Tab 14: Claude wanted to run sudo. Waiting.

Three permission prompts. Three hours of dead time.
No notification. No badge. No sound.
Just a blinking cursor in a tab I wasn't looking at.

That night I opened Chrome and stared at it.
42 tabs. Grouped by project. Favicons that change
when a page wants attention. Session restore.

My terminal had none of it.

So I forked iTerm2 and built what was missing.
10,745 lines of Swift and Obj-C in three days.

Status indicators that tell you when Claude needs you.
Tab groups by project. Session restore across restarts.
843 sessions — all searchable, all resumable.

And a cost engine that found $6,762 I didn't know I'd spent.

I'm open-sourcing it soon. Full build story in comments.

What's the worst thing you've missed
in a terminal tab you forgot about?

#ClaudeCode #AIEngineering #DevTools #DeveloperProductivity #BuildInPublic
```

---

## Post 2: $6,762 Cost Revelation (post 3-5 days LATER)

> Attach image: `04-history-dashboard.png` (upload natively)
> Put the Medium link as FIRST COMMENT

```
$6,762.

That's what I spent on Claude Code
before I could even see the bill.

Not in a cloud dashboard. Not in a monthly invoice.
Buried in token metadata that no tool bothered to read.

Here's the thing nobody tells you:

The Anthropic API returns FOUR token types per response.
Most tools — including Claude Code itself — only track TWO.

The other two? Cache tokens.

1.6 billion cache_read tokens on Opus alone.
At $1.50 per million, that's $2,400
that was completely invisible.

Input and output tokens were less than 2% of my real cost.
The cache was everything.

I only found this because I built a cost engine
that scans all 591 JSONL transcripts on my machine —
430 MB of conversation history.

That tool became part of something bigger:
a terminal I built for managing AI coding sessions at scale.

Tab groups by project. Session restore.
Searchable history. Live cost tracking.
A reasoning overlay that shows Claude's thinking in real time.

10,745 lines of Swift/ObjC. Three days.
Open-sourcing soon. Full writeup below.

Link in comments.

Are you tracking your full AI coding costs? Or just guessing?

#ClaudeCode #AIEngineering #DevTools #DeveloperProductivity #BuildInPublic
```

---

## Posting Strategy

- **Post 1 first** (permission-miss angle) — Tuesday or Wednesday, 8:00-9:30 AM US Eastern
- **Post 2** (cost revelation) — 3-5 days later, same time slot
- **Image:** Upload natively to LinkedIn (don't rely on link preview)
- **Link:** Put the Medium URL as the FIRST COMMENT, not in the post body — LinkedIn suppresses outbound links
- **Hashtags:** At the very end, after a blank line
- Post 1 image: `01-sidebar-claude-code.png` (sidebar with status dots — proves the problem is solved)
- Post 2 image: `04-history-dashboard.png` (cost dashboard — visual shock)
