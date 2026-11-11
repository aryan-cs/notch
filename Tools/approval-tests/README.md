# Approval tests

Manual end-to-end checks for Face Unlock's approvals, run against an
installed development build of Notch with your face set up.

- **`prompt.swift`** shows a system Touch ID prompt. With **Approve Touch ID
  prompts** on, Notch should grow its Face ID animation beside the notch,
  recognize you, and fill the prompt. `prompt result: true` means macOS
  accepted the password. Notch's log (`log show --predicate 'subsystem
  BEGINSWITH "theboringteam"'`) has the timings, under "Fill timing".
- **`signin-server.py`** serves a copy of Microsoft's sign-in pages. Open
  `http://127.0.0.1:8799/ms/password` in a browser, bring it to the front,
  and run `prompt`. With **Then finish signing in** on, Notch should press
  Sign in and Continue, which the server logs, and leave "Stay signed in?"
  alone. Only development builds treat `127.0.0.1` as a sign-in site.
- **`now-playing.swift`** plays silence as macOS's Now Playing, so the notch
  shows its music display. Run it with `prompt` to check that the Face ID
  square lands after the visualizer. Screenshots only show the notch with
  **Hide from screen recording** off.
