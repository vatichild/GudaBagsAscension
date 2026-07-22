# GudaBags for Ascension

[![Patreon](https://img.shields.io/badge/Patreon-F96854?logo=patreon&logoColor=white&style=for-the-badge)](https://www.patreon.com/cw/GudaAddons)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-29ABE0?logo=kofi&logoColor=orange&style=for-the-badge)](https://ko-fi.com/guda)

GudaBags puts all your bags into one window. It sorts items into categories, sorts your bags with one click, lets you search and filter, protects items you don't want to lose, and tracks what your other characters are carrying.

This is a fork of [GudaBags](https://github.com/GudaAddons/GudaBags) ported to [Project Ascension](https://ascension.gg/), which runs on the 3.3.5a client (Wrath of the Lich King, interface 30300). It is maintained on its own and is not kept in sync with the upstream Classic and Retail addon.

![GudaBags](https://media.forgecdn.net/attachments/description/1449496/description_08b5569f-f4b8-471e-b669-832a2573119a.gif)

---

## Features

### Three view modes

- **Category view.** Items are grouped automatically into things like Equipment, Consumables, Trade Goods and Quest Items. Click a category header to collapse or expand it.
- **Single view.** A flat grid, like the default bags but tidier.
- **Split view.** Each bag gets its own column. You choose how many columns to show, and which bags get a full width row of their own (the backpack or the keyring).

Views are set separately for your bags and your bank.

### Sorting

One click tidies everything up:

- Items are grouped by type, subtype, quality and name
- Partial stacks are combined so you get slots back
- Sorting runs in the background, so the game doesn't freeze while it works
- You can sort right to left, and reverse the stack order, if you prefer

### Categories

There are 22 built in categories, and you can change all of them:

- Recent Items, Quest, Junk, BoE, Weapons, Armor, Consumables, Trade Goods and more
- **Recent Items** collects whatever you picked up in the last few minutes. You choose how long items stay there, from 1 to 60 minutes.
- **Groups.** Categories sit in groups (Main, Other, Class) with headers you can collapse.
- **Merged groups.** Fold a whole group into one section if you want fewer headers.
- **Your own categories.** Build them from 16 kinds of rule: item type, name pattern, quality, tooltip text and so on. Rules can match on "any" or "all".
- **Drag and drop.** Reorder categories and move them between groups.
- **Group identical items.** Stacks of the same item share one slot in category view.

### Search and filters

- Start typing in the search box and only matching items stay on screen.
- Filter chips sit under the search box. Filter by quality, by item type, or by tags like BoE and recently picked up. Click a chip to turn it on or off.

---

## Quick access bars

Two small bars that stay on screen when your bags are closed.

### Quest item bar

Your usable quest items, so you don't have to open your bags mid quest.

- Click an item to use it
- Hover the bar to see the rest of your quest items
- Hides itself in battlegrounds, unless you turn that off
- Icon size and column count are adjustable

### Tracked item bar

Pin anything you want to keep an eye on. Handy when you're farming herbs, ore, cloth or reputation items.

- Ctrl+Alt+Click an item to start or stop tracking it
- Shows the total across all your bags
- Tracked items are remembered between sessions

---

## Bank

![Bank](https://media.forgecdn.net/attachments/description/1449496/description_ab02d162-25d4-46e8-b278-c332bd0aa788.png)

The bank works the same way as your bags:

- All three view modes
- The usual 7 bank bag slots, and you can buy new ones from the window
- You can look at any saved character's bank without logging into them

---

## Mail

- Your mail is saved, so you can look through it after you walk away from the mailbox
- You can read any saved character's mailbox
- Mail you send to an alt shows up in that alt's mailbox view straight away
- Totals the money sitting in your mail

---

## Guild bank

A full replacement for the guild bank window, with tab navigation, search, and saved contents you can browse later.

---

## Your other characters

- Hover any item and the tooltip tells you how many you have across the realm, split by bags, bank, mail and equipped
- Browse another character's bags, bank and mail without logging in
- The footer shows your gold added up across every character

---

## Keeping items safe

- **Locking.** Lock an item and it can't be sold, deleted or disenchanted by accident. Locked items get a lock icon and are skipped at merchants.
- **Equipment sets.** Anything in an equipment set is protected from selling. You can turn this off if you'd rather not.

---

## Automation

- **Open and close with windows.** Bags open when you talk to a merchant or open the mailbox, auction house, bank or a trade, and close again when you're done. Opening and closing are separate settings.
- **Sell junk.** Gray items are sold when you visit a merchant. Locked items and equipment set items are never sold.
- **Repair.** Gear is repaired at merchants who can do it. Off by default.

---

## Settings

Type `/gb config` or click the gear icon.

### Look

- Three themes: Guda (dark and plain), Blizzard (the default WoW look) and Retail
- Icon size from 22 to 64 pixels, plus font size and spacing
- Background opacity from 0 to 100%
- Lock the window so you don't drag it by accident

### Items

- Quality colored borders, with separate switches for gear and everything else
- Mark items you can't use
- Gray out junk, and optionally white gear too
- Mark items that belong to an equipment set

### Layout

- Columns: 5 to 22 for bags, 5 to 36 for the bank, 10 to 36 for the guild bank
- Show or hide the search box, filter chips, footer and item counts
- Group identical items in category view
- Show equipment sets as their own categories

### Profiles

- Save your settings under a name
- Load, delete or reset them whenever
- Import and export, so you can share settings or copy them to another character

---

## What works on 3.3.5a

This build targets interface 30300, so it turns on the things that exist in Wrath and leaves out the rest.

| Feature | Status |
|---|---|
| Keyring | Works |
| Quiver and ammo bags | Works |
| Soul bags (Warlock) | Works |
| Bank bag slots (7) | Works |
| Guild bank | Works |
| Reagent bag | Retail only, not here |
| Warband and character bank tabs | Retail only, not here |
| Item level on icons | Retail only, not here |
| Blizzard's own sorting | Retail only, GudaBags sorts instead |

---

## Equipment set addons

GudaBags reads equipment sets from:

- Blizzard's Equipment Manager
- ItemRack
- Outfitter

Items in a set are marked, and each set can show up as its own category.

---

## Commands

| Command | What it does |
|---|---|
| `/gb` or `/guda` | Open and close the bags |
| `/gb sort` | Sort your bags |
| `/gb bank` | Open and close the bank, when you're at a banker |
| `/gb config` | Settings |
| `/gb chars` | List your saved characters |
| `/gb count <itemID>` | Count an item across all characters |
| `/gb save` | Save your bags to the database now |
| `/gb status` | Show what expansion and features were detected |
| `/gb debug` | Turn debug messages on and off |
| `/gb help` | List every command |

### Commands for this port

The 3.3.5a client tells you a lot less than Retail does when something goes wrong, so this fork adds a few commands to fill the gap.

| Command | What it does |
|---|---|
| `/gberrors` | Show Lua errors that were caught. `/gberrors clear` empties the list. |
| `/gbdiag` | Dump what the compatibility shim did, plus frame and mouse diagnostics |
| `/gbdiag unblock` | Turn off the mouse on frames that are eating your clicks |
| `/gbtrace on\|off\|dump` | Leave breadcrumbs that survive a client crash |

---

## Languages

English, French, German, Russian, Portuguese, Spanish (Spain and Mexico), Chinese (Traditional and Simplified), Korean and Italian.

---

## Installing

1. Download the latest release
2. Put the `GudaBags` folder in your Ascension `Interface/AddOns/` directory
3. Restart the client, or type `/reload`

---

## Bugs and requests

Open an issue on [GitHub](https://github.com/vatichild/GudaBagsAscension/issues).

It helps to say which client build you're on, whether your bags were in category, single or split view, and to paste the output of `/gberrors`. This client swallows most Lua errors, so that output is often the only clue there is.
