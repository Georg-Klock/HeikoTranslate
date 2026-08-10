# Review archive

Issue and pull-request discussion from this project, as Markdown.

This history was migrated to a new remote, and GitHub has no migration
path for pull-request conversations — they exist only in the database of
the repository they were written in. Since they are the record of how the
work was actually reviewed, they are kept here as files instead.

**68 threads.** 27 others are held back: they contain personal
detail about people who did not sign up to be in a public repository, or
session notes rather than engineering discussion.

Numbers match the live issue tracker — the migration preserved them, so a
`#21` in a commit message still resolves to the right issue.

| # | kind | comments | state | title |
|---|---|---|---|---|
| [1](001-issue.md) | issue | 1 | closed | Picking the same language for home/partner while listening can crash the app and leaks a WebSocket session |
| [2](002-issue.md) | issue | 1 | closed | Audio-tap closure mutates MainActor-isolated converter state from the real-time audio thread (data race) |
| [3](003-issue.md) | issue | 1 | closed | Reconnect after a post-handshake session close has no backoff or attempt cap, unlike a pre-handshake error |
| [4](004-issue.md) | issue | 1 | closed | App can get stuck showing "Verbinde…" forever if both sessions in the pair permanently fail |
| [5](005-issue.md) | issue | 0 | closed | GermanUITests' golden-inventory scan has a blind spot for Text(String(format:...)) — a live string is unchecked |
| [6](006-issue.md) | issue | 0 | closed | LanguageSettingsSheet and CostSheet re-export the full diagnostic log on every SwiftUI body evaluation |
| [7](007-issue.md) | issue | 0 | closed | README.md and CLAUDE.md's ARCHITECTURE.md pointer still describe the old fixed three-session (de/en/es) design |
| [8](008-issue.md) | issue | 2 | closed | No CI: add a GitHub Actions workflow for L1 tests (L2/L3 as an optional, secret-gated job) |
| [9](009-issue.md) | issue | 1 | closed | No notice or consent mechanism for the conversation partner whose speech is sent to Google and retained on-device |
| [10](010-issue.md) | issue | 0 | closed | AI-assisted sessions must use branches + pull requests, not direct pushes to main |
| [11](011-issue.md) | issue | 0 | closed | Add a CLAUDE.md directive for cutting a TestFlight release (archive/export/upload + when to bump the marketing version) |
| [15](015-pull.md) | pull | 1 | closed | Close the German-scanner blind spot, stop log I/O in body, fix drifted docs |
| [17](017-pull.md) | pull | 1 | closed | CI: L1 on pull requests only |
| [19](019-issue.md) | issue | 0 | closed | GeminiLiveSession instances are never deallocated: URLSession(delegate: self) is never invalidated, and reconnect() replaces sessions without closing them |
| [20](020-issue.md) | issue | 0 | closed | Events and timers carry no run/instance identity: a stale drop-reconnect timer or a zombie session can corrupt the current run |
| [21](021-issue.md) | issue | 6 | closed | The L3 release gate mirrors the service's orchestration instead of exercising it — and has already drifted (no finalize-deferral path) |
| [22](022-issue.md) | issue | 0 | closed | deploy.sh/release.sh: the build-number pipeline still has unprotected failure windows (post-install revert; release.sh has no trap at all) |
| [23](023-issue.md) | issue | 0 | closed | TurnLogic.homeIsRealTranslation: the codes-corroboration bypass is unreachable whenever the partner session echoes |
| [24](024-issue.md) | issue | 5 | open | GeminiLiveSession: lifecycle flags are written on the main thread and read on the URLSession delegate queue with no synchronization; one pre-handshake failure can emit up to three .error events |
| [25](025-issue.md) | issue | 0 | closed | Microphone permission denial leaves two contradictory instructions on screen, permanently |
| [26](026-issue.md) | issue | 4 | open | TurnLogic edge cases: five verified or suspected gaps, each needing an L1 test to pin intended semantics |
| [27](027-issue.md) | issue | 0 | open | Tooling hygiene: stale DerivedData glob, inconsistent device selection, .venv ignored only by accident, no shell linting in CI |
| [28](028-issue.md) | issue | 0 | closed | UI/view-model small fixes: stale resume flag, ignored .shouldResume, tint keyed to German copy, stale CostSheet comment |
| [29](029-pull.md) | pull | 6 | closed | Invalidate URLSessions, close replaced sessions, pin async work to a token |
| [30](030-pull.md) | pull | 5 | closed | Rescue short translations beside an echo; make a denied mic recoverable |
| [31](031-pull.md) | pull | 9 | closed | Share the finalize-deferral policy between the app and the L3 harness |
| [32](032-issue.md) | issue | 0 | open | CostTracker undercounts: the token check drops late .usage events before handle() can record them |
| [33](033-pull.md) | pull | 0 | closed | Close the build-number pipeline's failure windows |
| [34](034-pull.md) | pull | 0 | closed | Trap signals, and set the point-of-no-return before the command |
| [35](035-pull.md) | pull | 14 | closed | TurnLogic edge cases: four defects, one documented non-defect |
| [38](038-issue.md) | issue | 1 | closed | The home-output character floors are German-calibrated but home is user-selectable |
| [39](039-pull.md) | pull | 0 | closed | A denied microphone recovers when Settings grants it (#25) |
| [40](040-pull.md) | pull | 5 | closed | Short answers really do survive an echo now (#23) |
| [41](041-pull.md) | pull | 21 | closed | Resume after an interruption, and say so (#28) |
| [42](042-issue.md) | issue | 1 | open | A failed automatic resume tells Heiko nothing he can act on |
| [47](047-pull.md) | pull | 0 | closed | Point CLAUDE.md at the repo's new URL |
| [48](048-issue.md) | issue | 0 | open | Five of the six UI languages have never been read by a speaker |
| [49](049-issue.md) | issue | 0 | open | CostSheet is unreachable — the token breakdown and the cost reset have no way in |
| [52](052-issue.md) | issue | 0 | open | Require explicit consent before automatic diagnostic transcript uploads |
| [53](053-issue.md) | issue | 0 | open | Contain the risk of the embedded Gemini key: separate key, usage monitoring, scripted rotation, in-app recovery |
| [54](054-issue.md) | issue | 0 | open | Do not treat an `unavailable` iPhone as deployable |
| [55](055-issue.md) | issue | 0 | open | End each diagnostic-upload background task exactly once on a serialized context |
| [56](056-issue.md) | issue | 0 | open | Preserve system Dynamic Type unless the user explicitly chooses an app override |
| [57](057-issue.md) | issue | 0 | open | Serialize and cancel pending microphone starts across rapid taps and backgrounding |
| [58](058-issue.md) | issue | 0 | open | Expose the custom language wheels as semantic, adjustable VoiceOver controls |
| [59](059-issue.md) | issue | 0 | open | Do not forward mic audio to a replacement session before its new setup completes |
| [60](060-issue.md) | issue | 0 | open | Make AVAudioEngine startup/restart idempotent and roll back partial setup |
| [61](061-issue.md) | issue | 0 | open | Generate the Xcode project before running the release test gate |
| [62](062-issue.md) | issue | 0 | open | Run the L0 build-number failure-window suite in CI |
| [63](063-issue.md) | issue | 0 | open | Make L3 replay fail on unrecognized Gemini server frames |
| [64](064-issue.md) | issue | 0 | open | Make the L2 protocol probe exit nonzero for server errors or empty results |
| [65](065-issue.md) | issue | 0 | open | Restore the documented `Tools/targetprobe.sh` launcher |
| [66](066-issue.md) | issue | 0 | open | Cover Korean and Chinese in the language-pair invariant test |
| [67](067-issue.md) | issue | 0 | open | EU App Store: declare DSA trader status before a German launch (TestFlight is exempt, the App Store is not) |
| [68](068-issue.md) | issue | 0 | open | App Privacy nutrition labels must be completed, and must match what the app actually does |
| [69](069-issue.md) | issue | 0 | open | Unlisted App Distribution has to be requested from Apple — it is not a switch in App Store Connect |
| [70](070-issue.md) | issue | 0 | open | App Store listing metadata does not exist yet (screenshots, description, support URL, age rating) |
| [71](071-issue.md) | issue | 1 | open | App Store readiness: tracking issue for a DE + US launch (unlisted) |
| [72](072-issue.md) | issue | 0 | open | Separate translation languages from interface languages |
| [73](073-issue.md) | issue | 1 | open | Output-substance thresholds are measured in characters and are not comparable across scripts |
| [74](074-issue.md) | issue | 0 | open | Expand translation coverage for a California audience: Tagalog and Vietnamese first |
| [75](075-issue.md) | issue | 0 | closed | Direction resolution needs a strategy for closely related language pairs |
| [77](077-pull.md) | pull | 11 | closed | Direction: echo detection fixes the de↔es misattribution (#75) |
| [84](084-pull.md) | pull | 12 | open | TurnLogic: per-session vote evidence replaces token overlap (#83, the shipped #77 blockers) |
| [87](087-pull.md) | pull | 0 | closed | CI: run L1 on merges to main, skip docs, stop brew auto-updating |
| [88](088-pull.md) | pull | 0 | open | Guard deployments against unavailable devices |
| [90](090-pull.md) | pull | 1 | closed | App Store paperwork drafts: listing, privacy labels, age rating, unlisted, EU trader, screenshots |
| [91](091-pull.md) | pull | 0 | open | Log both session transcripts at commit |
