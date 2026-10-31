# Agent instructions for player addons

Read `README.md`, `CONTRIBUTING.md`, and the relevant `addons/<name>/README.md` before editing. This is the public shared **player addon** repository, not the private VanaDreams server or launcher.

- Keep each addon in its own `addons/<name>/` folder. Change only the requested addon and its ownership note unless a maintainer coordinates a shared change. Preserve unrelated work and contributor credit.
- Do not invent a player's identity, asset authorship, license, or redistribution permission. Ask for missing ownership facts through the maintainer; record unknowns plainly. Do not commit logs, player data, credentials, or downloaded samples that are not part of the addon.
- Use a short-lived branch from current `main` and a pull request to `main`. State changed files, version, dependencies, and tests. The addon-folder maintainer convention is for human review; GitHub Write permission is repository-wide.
- Review downloaded code and assets before use. Run only focused safe tests until code has been reviewed. Do not modify the private game server, launch paid GitHub Actions, or claim an in-game test that was not performed.
- A package update alone does not update the launcher catalog. Coordinate any catalog version change separately in `VanaDreams/vanadreams-launcher`, including both catalog copies, and verify the published package path before saying players can install it.

No contributor access is implied by these instructions. A maintainer must verify the person's GitHub account before inviting them; a personal repository is optional for a collaborator here.
