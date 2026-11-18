# easyTH 0.4.1-vd (compatibility and safety revision)

Original addon: **Arielfy**, https://github.com/ariel-logos/easyTH . Original author
metadata and MIT license are preserved. This is an independently modified copy,
not an upstream release or a server change.

## Install manually when ready

1. Unload an older copy with `/addon unload easyTH` if it is running.
2. Back up the old `easyTH` addon folder. Extract this archive so the files are at
   `Ashita/addons/easyTH/easyTH.lua` (not nested `easyTH/easyTH/easyTH.lua`).
3. Use `/addon load easyTH` in Ashita 4.

Nothing in this package installs itself, injects packets, edits game memory,
changes server files, or changes the auto-load list.

## Commands and display

- `/easyth anyjob`: toggle display/tracking on any observer job, not just THF main.
- `/easyth reset`: forget all observed monsters, useful after a missed death packet.
- The window follows your latest observed attack/weapon-skill target. Party actions
  can update other monsters without stealing your current displayed target.
- **Unknown (no proc observed)** means no numeric TH upgrade has been received.
  It does NOT mean TH0 and does not guess TH1 or a gear/trait baseline. A TH-gear-only
  character can be tracked in anyjob mode, but this addon cannot discover an initial
  TH level the server never broadcasts. It may correctly stay Unknown.
- Only received TH proc packets produce a numeric level. This is not a gear calculator.
  Reloading or resetting loses prior observations until another proc arrives.

## Corrections

- Every monster starts with its own unknown level; no carryover from another target.
- All 18 alliance slots are scanned, regardless of member main/sub job. Anyjob does
  not require a THF party member. Parties are refreshed for each relevant action.
- All action targets are processed. Latest observed server level is authoritative.
- Zone transitions, logout and manual reset clear stored identities. If death/zone
  packets are missed, use reset; the addon cannot reconstruct missed history.
- Bounds-checked packet reading and protected parsing reject malformed/truncated data.
- ImGui Begin/End are balanced even when the window is clipped.

## Compatibility and validation

Source checked against Vanadreams action packet layout: action0x028, proc kind7,
message603 and proc value are consistent with its Treasure Hunter implementation.
Death messages6/20 in0x029 clear the matching enemy. Default observer job is THF.
Requires Ashita4 common/imgui libraries, its memory APIs and LuaJIT environment.

47 isolated LuaJIT tests pass, including every alliance slot, anyjob without a THF,
per-enemy state, numeric proc decoding, multiple targets, death/zone/reset, malformed
and truncated packets (including1,000 deterministic fuzz inputs), and ImGui balancing.
Tests use actual addon/parser/tracker code with mocked Ashita/ImGui and synthetic
packets. **No actual Ashita/FFXI session was loaded or tested**, and no installation
was performed. These checks are not a guarantee against every client/plugin conflict.

Tests are provided in `tests/test_easyth.py`; run with Python, pytest and lupa:
`python -B -m pytest tests/test_easyth.py -q -p no:cacheprovider -p no:faulthandler`.
On Windows, disabling pytest faulthandler avoids noisy reports from LuaJIT's caught
SEH errors during deliberately malformed-packet tests; Lua errors are still asserted.

## Licenses

- Original easyTH and the new tracker: MIT (`LICENSE`, Copyright2025 Arielfy retained).
- `parser.lua` and `bitreader.lua`: Ashita Development Team GPL-3.0-or-later, original
  copyright/license headers retained. Full license is `COPYING-Ashita-GPL-3.0.txt`.
- The original README is retained as `README.upstream.md` for attribution/history;
  the behavior notes above supersede its descriptions for this modified version.

## VanaDreams maintenance

Published by VanaDreams with Lee's authorization. Original author: Arielfy; fixes maintained by VanaDreams. No separate player maintainer is assigned. Select easyTH in the launcher addon picker to install this opt-in addon. Original source and component licenses are preserved.

