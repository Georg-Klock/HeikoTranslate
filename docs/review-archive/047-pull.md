# pull #47 — Point CLAUDE.md at the repo's new URL

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-07T19:55:04Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/47

---

The GitHub account was renamed, so `github.com/georgkloeck/HeikoTranslate` is now a redirect. `git push` still works through it and says so on every push:

```
remote: This repository moved. Please use the new location:
remote:   https://github.com/Georg-Klock/HeikoTranslate.git
```

`CLAUDE.md` is the one place the old URL was written down in the repo itself — in the rule that names the remote as the offsite backup. A backup nobody can find is not one.

The local `origin` was updated separately; that is machine state, not repo state.

One line. No code, no tests affected.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
