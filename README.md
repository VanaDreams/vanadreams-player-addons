# VanaDreams player addons

Community supplied Ashita v4 addons distributed through the VanaDreams launcher. Each addon has its own folder under `addons/`.

## RemaTracker

`addons/rematracker` contains the files supplied on 31 October 2026. Install the whole folder under Ashita `addons/rematracker` and load it with `/addon load rematracker`. The Magian logic requires `magiancore.lua`; the celebration uses `victory.wav` and `moogle_dance.png`. `/rt help` lists commands, and `/rt selftest` runs the included logic checks.

The files were supplied by a VanaDreams player. The Lua source identifies its author as `Claude`; the player's name and asset authorship have not yet been supplied. No license has been asserted for these files. The sample `npc_log.txt` was excluded because it is generated player session output.

To update the addon, change its Lua `addon.version` and the matching entry in both launcher catalog files so installed players receive the update. Submit changes through a pull request until maintainer access is arranged. No automated builds are configured.
