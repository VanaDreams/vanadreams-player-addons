# VanaDreams player addons

This public repository is a shared home for player-made **Ashita v4 addons** offered through the VanaDreams launcher. Each addon lives in its own `addons/<name>/` folder. The private game server is a different repository.

## For addon authors

You need a **personal GitHub account** to sign in and contribute directly. You do **not** need to create or maintain a personal repository once a VanaDreams maintainer gives your account collaborator access here. Tell a maintainer your exact GitHub username and which addon folder you maintain. Until access is arranged, you can send your files to a maintainer for review and publication. Do not post passwords or tokens.

For each update, make a short-lived branch, edit only your addon folder, and open a pull request to `main`. A maintainer reviews and merges it. GitHub Write access, if granted, applies to the **whole repository**; the folder ownership recorded here is a review convention, not a GitHub permission boundary. See [CONTRIBUTING.md](CONTRIBUTING.md) for the steps. Agents should read [AGENTS.md](AGENTS.md); Claude should also read [CLAUDE.md](CLAUDE.md).

## RemaTracker

`addons/rematracker` contains the files supplied on 31 October 2026. Install the whole folder under Ashita `addons/rematracker` and load it with `/addon load rematracker`. The Magian logic requires `magiancore.lua`; the celebration uses `victory.wav` and `moogle_dance.png`. `/rt help` lists commands, and `/rt selftest` runs the included logic checks.

The files were supplied by a VanaDreams player. The Lua source identifies its author as `Claude`; the player's identity and asset authorship are not yet confirmed. No license has been asserted for these files. The sample `npc_log.txt` was excluded because it is generated player session output. The [addon ownership note](addons/rematracker/README.md) records its current maintenance status without guessing credit.

When an addon release is ready, the maintainer updates its Lua version and the matching entry in **both** launcher catalog files so installed players can receive the update. A repository change alone does not update the launcher. This repository has no automated build workflow.
