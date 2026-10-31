# RemaTracker maintenance

RemaTracker 2.0 was supplied by a VanaDreams player on 31 October 2026. The player's GitHub identity has not been confirmed, so a repository maintainer currently reviews updates to this folder. The Lua source identifies its author as `Claude`; the ownership of `victory.wav` and `moogle_dance.png` has not been established. No license has been asserted for these files. Do not replace those unknowns with guessed credit.

Install the entire folder at `Ashita/addons/rematracker`. It requires `rematracker.lua`, `magiancore.lua`, `victory.wav`, and `moogle_dance.png`; `magiancore_test.lua` is the included offline logic test. Load with `/addon load rematracker`; `/rt help` lists commands and `/rt selftest` runs the logic checks.

Updates should stay in this folder and go through a short-lived branch and pull request to `main`. Coordinate the addon version and the launcher catalog version with a maintainer before describing the update as available to players.
