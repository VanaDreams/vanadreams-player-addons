# VanaDreams distribution of nolock

VanaDreams supplies this third-party addon unchanged. It does not claim authorship or maintain an edited fork.

- Addon: **nolock 1.0.0**, for **Ashita v4**.
- Author: **WinterSolstice8**. The original pattern and assembly patch are credited to **atom0s** in the supplied source and README.
- Upstream: <https://github.com/WinterSolstice8/nolock>, archived at the time of import.
- Source revision: [`2140687599c31650714468da9446b3362f5eb5c9`](https://github.com/WinterSolstice8/nolock/tree/2140687599c31650714468da9446b3362f5eb5c9).
- License: GNU General Public License version 3, supplied in [LICENSE](LICENSE). Keep the license and original notices with redistributed copies.
- Maintenance: VanaDreams handles packaging and launcher listing only. No upstream maintenance commitment is asserted.

## Installation and use

Copy this complete folder to `Ashita-v4beta/addons/nolock/`, retaining `nolock.lua`, `README.md`, `LICENSE`, and this distribution note. No additional addon or plugin dependency is declared by the supplied source. Load with `/addon load nolock`; unload with `/addon unload nolock`.

The addon patches the running game's engage/disengage animation-lock code in memory and restores the saved bytes on unload. It does not enable movement during other animations. The upstream README warns of temporary cosmetic weapon/hand misalignment. If its signature cannot be found, it prints `[nolock] Could not locate address to patch` and does not apply the patch.

## Provenance and verification

The supplied archive was `nolock-main.zip`. All three upstream files below are byte-for-byte identical to that archive and the upstream revision. This distribution note is a separate VanaDreams packaging document; no upstream file was edited.

SHA-256:

- Original archive: `fd57825e79412be4dd84a0d383f7702b3c33dadb530fab67a597d72d7f4c28ab`
- `nolock.lua`: `bc0e4e87d1b793066e6d9d012386b14244ead93cb97e8e5ee7c54b5c66afb31c`
- `README.md`: `9312be49b07852c749372ea248ea7a8c88c8bdd1fd7940ca5db0f46f13b64b8d`
- `LICENSE`: `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`

Review covered source, license, archive integrity, byte identity, and the launcher's Ashita v4 package format. The addon was not executed, and in-game behavior was not tested. Compatibility with every FFXI client build is not guaranteed by this static review.

The launcher catalog is maintained separately in `VanaDreams/vanadreams-launcher`. This package alone does not add the live launcher entry; the package must be merged before its matching catalog change.
