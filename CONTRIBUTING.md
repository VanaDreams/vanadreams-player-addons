# Contributing an addon

1. Create a GitHub account if you do not have one. Give a VanaDreams maintainer your **exact GitHub username** and the addon folder you want to maintain. A personal repository is not required for a collaborator in this shared repository. Wait for the invitation and accept it before trying to push.
2. Check `addons/<name>/README.md` for the current maintainer and dependencies. Coordinate the update so two people do not edit the same folder at once. New addons get their own folder and README with maintainer status, install steps, required files, and verified credit.
3. In your local clone, fetch `main` and make one short branch for the update:

   ```text
   git clone https://github.com/VanaDreams/vanadreams-player-addons.git
   cd vanadreams-player-addons
   git switch main
   git pull --ff-only origin main
   git switch -c fix/rematracker-description
   ```

4. Change only your addon folder unless a maintainer coordinates a shared change. Keep generated logs, player data, secrets, and unrelated downloads out. Preserve source credit and asset provenance; do not add a license or claim rights for someone else's files without their permission. Test the addon in your own Ashita installation and record what you checked.
5. Commit and push the branch, then open a pull request against this repository's `main`. Include the addon name, what changed, version, required files/assets, tests, and known limits. Ask a maintainer to review and merge it; do not push directly to `main` or force-push shared branches.

If you have no GitHub account yet, send the files and your preferred credit to a maintainer. They can review and publish on your behalf. That route does not give you authenticated access to edit the repository yourself.

**Launcher releases:** after review, coordinate a matching version change in both `VanaDreams/vanadreams-launcher` catalog files. The launcher update is a separate reviewed change; changing this repo does not automatically publish a new catalog entry.

GitHub collaborator permission applies to the whole repository. The addon-folder ownership notes guide review and coordination; they do not enforce folder-scoped access.
