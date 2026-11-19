# Changelog

## 1.11.4-lite
- "Do that again" no longer fires for categories that are turned off.
- Fight: a "Level N <job>" RoE is only taken when you are one level below it.
- Auto mode only removes other-zone zone RoEs and off-day crystals/stones, only above 29 active, never a RoE with a requirement above 10 (roe_goals.lua).
- April 2026 RoE list: objective counts for the removal rule, 22 missing RoEs added, /roehelper info.
- Mute toggle (/roehelper mute, button in the window).
- Making room: no 29-count gate, Spoils removable (off-day stones, other-zone RoEs, then Spoils).
- Drops also detected from chat lines (fallback for the pool packet).
- First lite build: plain ImGui theme.lua stand-in, no skins/aurora/windowskin/yunastyle files, no assets or fonts. Features unchanged. Not tested in game.
- No combo box or child windows (some Ashita builds, e.g. Vana'dreams, reject them): the conflict zone picker is a collapsing list. Not tested in game.
