# Pit Bets

A Cyber Engine Tweaks mod for Cyberpunk 2077. Bet eddies on underground fights between NPCs in Pacifica and Kabuki: boxers, chromed brawlers, even mechs. Each fighter's cyberware sets their odds, and it also buffs them in the actual fight. You can sabotage a fighter with quickhacks before the bell, but if the bookies catch you, your bet is void and they come for you.

## Requirements

- Cyberpunk 2077 2.x
- [Cyber Engine Tweaks](https://www.nexusmods.com/cyberpunk2077/mods/107)
- [Codeware](https://www.nexusmods.com/cyberpunk2077/mods/7780) (spawns the fighters. Without it you can still draft fighters from the crowd.)

## Install

Extract the release zip into your game folder, or install it with Vortex / MO2. The mod goes in:

```
Cyberpunk 2077/bin/x64/plugins/cyber_engine_tweaks/mods/PitBets/
```

From source, run `build.ps1` and use the zip in `dist/`, or copy the `PitBets` folder there yourself.

## How to play

1. Go somewhere open in Pacifica or Kabuki. Fighters spawn about 8 m in front of you.
2. Open the CET overlay. The **Pit Bets** window is there (bind a hotkey to hide or show it).
3. Pick a venue and press **Get tonight's card**. Reroll until you like the matchup.
   - **Draft looked-at NPC** puts whoever you're aiming at into a corner instead.
4. **Open the book.** The fighters walk out and the odds lock.
5. Place your bet before the bell, or ring it early.
6. Optional: **sabotage**. Look at a fighter and spend RAM:
   - *Short Circuit* (3 RAM): -25% health
   - *Cyberware Malfunction* (4 RAM): their best implant goes offline
   - *Armor Shred* (2 RAM): halves armor
   Any shot, blade or quickhack you land on a fighter counts too. Every act can be spotted: Pacifica starts at 30%, Kabuki at 20%, and each act after that adds 12%.
7. A fight ends on a knockout, or goes to the judges (more health wins) after 120 s. A double KO refunds your stake.

If you get caught, your stake is gone and three of the bookie's gang spawn around the ring, hostile to you.

## How the odds work

Rating = class base (Boxer 40, Chromed Brawler 55, Mech 110, drafted NPC 25 + level) + implant ratings, multiplied by a ±10% form roll. Win chance is `rA^1.6 / (rA^1.6 + rB^1.6)`, capped at 90/10. Payout is `0.92 / p`, rounded down, so the house keeps an 8% edge.

Implants also apply real stat modifiers (max-health multiplier and armor). That pushes the actual fight toward the odds, but upsets happen.

## Hotkeys (set in CET > Bindings)

- **Toggle Pit Bets window**
- **Ring the bell**

## Customising

`PitBets/roster.lua` holds the fighters, cyberware, venues, bookies and handles. Each fighter template lists candidate TweakDB character records, and only the ones that exist in your game get used. The **Record check** section of the window shows which records loaded. To add NPC types, look up their record IDs in AMM or the WolvenKit Tweak Browser.

Stats and settings are saved in `PitBets/stats.json`.

## Known limits

- Fights happen wherever you're standing. There's no fixed arena location.
- NPCs use their own weapons. Choose melee records if you want fist fights.
- Mech records are experimental, and their AI may not engage.
- Some gang NPCs nearby may join a fight.

## Development

The game logic runs outside the game against fake engine, ImGui and CET APIs:

```bash
luajit tests/run.lua
```

Layout:

| File | Role |
|---|---|
| `init.lua` | CET events, hotkeys, the OnHit hook, save/load |
| `pit.lua` | Fight-night state machine (idle → card → spawning → betting → fighting → result) |
| `engine.lua` | Every game API call, each wrapped in `pcall` |
| `roster.lua` | Data: fighters, cyberware, venues, sabotage |
| `odds.lua` | Odds, payouts, detection math |
| `ui.lua` | ImGui window and in-game HUD |

## License

MIT. See [LICENSE](LICENSE).
