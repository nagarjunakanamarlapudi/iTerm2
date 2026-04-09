# Twitter Thread — Netra Launch

## Thread (7 tweets)

**1/7**
I spent $6,762 on Claude Code before I could even see the bill.

Not in a dashboard. Not in a monthly invoice. Buried in token metadata that no tool I was using had bothered to read.

Here's the full story, and what I built to fix it:

**2/7**
The week before, I had 14 Claude Code sessions open across 8 projects.

One broke my auth flow. I didn't know which one.

I clicked through tab after tab of identical terminal output. Meanwhile, Claude silently asked for permission in 2 other tabs I hadn't noticed.

**3/7**
Then it hit me: I have more terminal sessions open than browser tabs.

But my browser is a decade ahead of my terminal in every way that matters — tab groups, session restore, searchable history, favicon notifications.

My terminal? A flat list of identical-looking tabs.

**4/7**
This gap didn't matter when terminals were for `make` and tailing logs.

It matters enormously now. AI turned the terminal into a cockpit. You're running 10 agents at once, making decisions in natural language, and your tooling gives you... nothing to manage it.

**5/7**
So I forked iTerm2 and built Netra. 10,745 lines in 3 days.

- Tabs auto-group by project
- Cyan dot = Claude working. Amber = needs permission. Rose = dead.
- Full session restore on restart
- Cmd+Opt+B = searchable history of every session you've ever run

**6/7**
Then I built the cost engine.

The API returns 4 token types. Most tools only track 2. The hidden ones — cache_read and cache_creation — were 98% of my real spend.

1.6 BILLION cache_read tokens for Opus. $2,400 completely invisible.

Now it's a live dashboard with a taxi-meter cost counter.

**7/7**
Browsers figured out attention management for knowledge workers a decade ago.

Terminals need the same thing for AI-powered engineering: tab groups, session restore, history, notifications, cost visibility.

Netra is in private beta. DM me how many Claude Code sessions you typically run. I'll send access.

[link to Medium article]

---

## Standalone Tweets (use individually to promote the article)

**Tweet A — The Shock Number**
I spent $6,762 on Claude Code before I could even see the bill.

The Anthropic API returns 4 token types per response. Most tools only track 2. The other 2 — cache_read and cache_creation tokens — accounted for 98% of my real cost.

1.6 billion cache_read tokens for Opus alone. $2,400 invisible.

I built a tool to make it visible. [link]

**Tweet B — The Pain Point**
I had 14 Claude Code sessions open across 8 projects. One of them just broke my auth flow. I didn't know which one.

Tab. Tab. Tab. Scrolling through identical terminal output trying to remember which session was which.

Meanwhile, Claude silently asked for permission in 2 tabs I hadn't noticed.

The terminal UX is broken for AI workflows. [link]

**Tweet C — The Browser Framing**
Your browser gives you: tab groups, session restore, searchable history, favicon notifications.

Your terminal gives you: a flat list of identical tabs.

This didn't matter when terminals were for `make` and tailing logs.

It matters enormously now that AI turned the terminal into the center of engineering work. [link]

**Tweet D — The Build Stats**
10,745 lines of Swift and Objective-C. 3 days. A fork of iTerm2 purpose-built for managing multiple AI coding sessions.

Cyan dot = Claude is working
Amber badge = Claude needs permission
Rose = something died

I stopped polling my terminal tabs. For the first time, I could actually focus. [link]

**Tweet E — The Invisible Cost**
Claude Code's own session metadata only tracks input and output tokens.

But cache_read_input_tokens and cache_creation_input_tokens are where the real money is.

For Opus, input + output were less than 2% of my actual cost. The cache was everything.

Nobody is talking about this. [link]

---

## Best Images to Attach

1. `04-history-dashboard.png` — for cost-focused tweets (A, E)
2. `03-command-center.png` — for product-focused tweets (D)
3. `01-sidebar-claude-code.png` — for UX-focused tweets (B)
4. `05-browser-vs-terminal.png` — for thesis tweets (C)
