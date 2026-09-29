# MediaRemoteAdapter pin (2026-09-28)

## Why
The adversarial review (upstream issues #190 CPU 100%, #214/#191 stops working) found the pinned
ejbills/mediaremote-adapter 70bff25 leaves its stdout readabilityHandler in place at end of file, so
when the perl helper exits the handler spins; nothing in the app restarted the helper, so track
detection stopped until relaunch. ejbills fixed the spin in b97fa53f (2026-04-12), but ejbills removed
the upstream BSD 3-Clause LICENSE in d822a6ba (2025-12-23, "fork diverged significantly"); GitHub lists
the repo as unlicensed. Every revision with the fix is after that. Later ejbills commits also change
notification timing (track-change coalescing, event-driven updates, listener restart every 100 events)
and the onTrackInfoReceived signature (optional TrackInfo).

## Decision (owner)
Own fork, minimal fix: github.com/dizzysound/mediaremote-adapter, branch lossless-switcher, based on
70bff25 (still carries the BSD-3 LICENSE of ungive/mediaremote-adapter), plus 2e59752, written
independently: remove the handler at EOF and in stopListening(); the terminationHandler acts only for
the current listener process. The app (MediaRemoteController) now restarts the helper when it exits on
its own: 1 s, doubling to 60 s while it keeps dying within 30 s of a start; not after stop().
Not taken: ejbills' later crash/leak fixes (buffer race 9c8794ac, ARC/autorelease 28a9d0bd, "fix cpu"
5deebcac). Revisit if those crashes show up.

## Measurements (desk, this Mac)
- eof_spin_test.swift (pipe closed, handler left in place vs removed): pinned logic 1,017,502 handler
  calls in 1 s, 1.00 s CPU; fixed 2 calls, 0.00 s.
- harness/ (real perl helper, kill -9, then restart, then stopListening):
  - 70bff25: onListenerTerminated x1, CPU over 2 s after the kill 2.003 s (one core); stopListening
    then reported a second termination (would trigger a restart after an intentional stop).
  - 2e59752: onListenerTerminated x1, CPU 0.000 s; restart gets a new helper; stopListening reports
    nothing, no helper left.
- App: typecheck build resolves the fork (checkout has both `readabilityHandler = nil`). Not benched
  in the app; the Xcode build re-resolves the package from the new URL on first open.
