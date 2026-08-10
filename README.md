# Heiko Translate

A one-button iPhone app for live speech translation — English↔German and
Mexican Spanish↔German, direction detected automatically — built as a gift
for Heiko. Voice-to-voice translation runs through Google's Gemini Live API.

This file is **setup only**. The other documents each own one thing:

| Document | Owns |
|---|---|
| `SPEC.md` | Product truth — behavior and the R1–R8 invariants |
| `TESTING.md` | Test truth — levels L1–L4 and current status |
| `docs/ARCHITECTURE.md` | Technical truth — sessions, turn logic, wire protocol |
| `docs/history.md` | The original plan (historical; do not build against it) |
| `CLAUDE.md` | Working rules and commands for AI-assisted sessions |

## First-time setup (on your Mac)

1. **Install xcodegen** (generates the `.xcodeproj` from `project.yml`; the
   project file itself is gitignored and regenerated):
   ```
   brew install xcodegen
   ```

2. **Add your Gemini API key:**
   ```
   cp HeikoTranslate/Resources/Secrets.plist.example HeikoTranslate/Resources/Secrets.plist
   ```
   Then edit `Secrets.plist` and paste in a real key from
   [aistudio.google.com](https://aistudio.google.com/apikey). This file is
   gitignored — it will never get committed.

3. **Generate and open the project:**
   ```
   xcodegen generate
   open HeikoTranslate.xcodeproj
   ```
   Re-run `xcodegen generate` whenever `project.yml` changes.

4. **Set your signing team:** in Xcode, select the `HeikoTranslate` target →
   *Signing & Capabilities* → set your team. (A free Apple ID suffices to
   run on your own device; the paid Developer Program is needed for
   TestFlight.)

5. **Run it** on your iPhone (Xcode → select your device → ▶). First launch
   asks for microphone permission — accept it. Echo cancellation and
   speaker/mic behavior are device things; the Simulator is fine for UI and
   connection checks.

6. **If audio stops coming back**, check the Xcode console first: every
   server message the code doesn't recognize is printed as
   `GeminiLive[...] unrecognized message: ...` rather than silently dropped.

## Running the tests

Before any human-with-a-phone testing, L1–L3 must pass (`TESTING.md`):

```
xcodebuild test -project HeikoTranslate.xcodeproj -scheme HeikoTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet   # L1
python3 Tools/livetest.py --text "a test sentence" --target de       # L2
Tools/l3replay.sh                                                    # L3
```

## Getting it onto a tester's iPhone (TestFlight)

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/)
   ($99/year) using your own Apple ID.
2. In Xcode: *Product → Archive*, then use the Organizer to upload the
   archive to App Store Connect.
3. In [App Store Connect](https://appstoreconnect.apple.com), open
   *TestFlight* for the app and add your tester by email.
4. The tester installs the free **TestFlight** app, accepts the emailed invite,
   and installs Heiko Translate through it. Best done together on a call the
   first time.
5. TestFlight builds expire after ~90 days — repeat steps 2–3 to push
   updates or renew.

## Project layout

```
HeikoTranslate/
  HeikoTranslateApp.swift        App entry point
  ContentView.swift              The single screen (bubbles + one button + status)
  ConversationViewModel.swift    UI state; owns the translation service
  Models/
    TurnLogic.swift              THE turn state machine (pure, L1-tested):
                                 spoken language -> translator -> commit gates
    FillerWords.swift            Hesitation stripping (adversarially reviewed)
  Services/
    GeminiLiveSession.swift            One WebSocket to Gemini Live Translate,
                                       fixed to a single target language
    GeminiLiveTranslationService.swift Runs the two sessions of the selected
                                       language pair concurrently, audio I/O,
                                       turn timers, reconnects
    AppConfig.swift                    Loads the API key from Secrets.plist
  Resources/
    Secrets.plist.example        Template — copy to Secrets.plist, add your key
Tests/                           L1 unit tests (run via xcodebuild test)
Tools/                           livetest.py (L2), L3 replay harness
TestAudio/                       Recorded utterances for L3 replay
docs/                            ARCHITECTURE.md, history.md
design/                          Icon sources and design iterations
```
