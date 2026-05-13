# Promotion Notes

Use these notes when announcing Token Terrier in developer communities. Keep the
message focused on the practical difference: Token Terrier monitors token usage
from local and remote machines, not just the Mac running the menu bar app.

## Positioning

Token Terrier is a macOS menu bar app for monitoring Claude Code and ChatGPT
Codex token usage across local and remote machines.

The differentiator is remote monitoring: run the lightweight Go server where the
agents run, then watch live usage from the Mac menu bar over HTTP/SSE.

## Short Launch Post

```text
I built Token Terrier: a macOS menu bar app for monitoring Claude Code and
ChatGPT Codex token usage across local and remote machines.

Run the lightweight Go server where your agents run, then watch live usage from
your Mac menu bar over HTTP/SSE.

The menu bar icon is Bapful, my Bedlington Terrier, and he runs faster as token
burn increases.

https://github.com/codemoo/token-terrier
```

## Show HN Draft

Title:

```text
Show HN: Token Terrier, a macOS menu bar token monitor for Claude Code and Codex
```

Body:

```text
I built Token Terrier because my Claude Code and Codex work is not always on the
same Mac I am using.

The project has two runtime pieces: a SwiftUI macOS menu bar app and a small Go
HTTP/SSE server. Run the server on the machine with the credentials and session
logs, then view live Claude/Codex usage from the menu bar. It can also read
locally when everything is on one Mac.

The app uses GitHub Releases and Sparkle for updates. Current builds are
ad-hoc signed, so broader distribution work is still pending.

Repo: https://github.com/codemoo/token-terrier
```

## Community Checklist

- Pin the repository on the owner profile.
- Use a direct GitHub Releases link when sharing install instructions.
- Mention remote monitoring in the first sentence.
- Mention current signing limitations honestly.
- Avoid posting machine-specific deployment details, server URLs, tokens, or
  private infrastructure notes.

## GitHub Metadata

Suggested description:

```text
macOS menu bar app for monitoring local and remote Claude Code / Codex token usage
```

Suggested topics:

```text
macos, menubar, swiftui, claude-code, codex, openai, token-usage, sparkle, go
```
