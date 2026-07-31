# Vendor Search

A merchant quality-of-life addon for **Ascension WoW** (Conquest of Azeroth, 3.3.5a).

Vendors with long inventories — dungeon-token gear, reputation quartermasters, the reagent guy
with three pages of stuff — are a pain to scan. Vendor Search adds a search bar right below the
merchant window so you can **find an item by name** (type `ironfoe`, jump straight to it) and
**filter by stat** (tick Spell Power + Hit to see only gear with both).

*No libraries, one Lua file, ~12 KB.*

## Features

- **Live name search** — type part of a name and the vendor list filters as you type.
- **Multi-select stat filter** — tick as many stats as you want; it shows only items that have
  **all** of them (e.g. Spell Power + Hit, or Attack Power + Crit). 21 stats covered:
  Intellect · Spirit · Spell Power · Spell Damage · Healing · MP5 · Strength · Agility ·
  Attack Power · Armor Pen · Crit · Haste · Hit · Expertise · Spell Pen · Stamina · Resilience ·
  Defense · Dodge · Parry · Block.
- **Reads the real tooltip** — matches against the item's actual tooltip text, so procs, "Equip:"
  lines and Ascension's custom stats all count. Name + stats combine.
- **Match counter** and an **"All items (clear stats)"** reset in the dropdown.
- **Completely safe** — buying, right-click purchase, shift-click links and stack-splitting always
  hit the item you see (see *How it works*).

## Install

**Recommended — from Releases (cleanest):**

1. Open the [**Releases**](https://github.com/Leemo94/VendorSearch/releases/latest) page and, under
   **Assets**, download `VendorSearch-x.y.z.zip`.
2. Unzip it and drop the **`VendorSearch`** folder into your Ascension client's `Interface\AddOns\`
   directory (the folder containing `Wow.exe` / `Interface\` — in the Ascension Launcher, use
   *Options → Open game location*).
3. Restart the game or type `/reload`.

**If you use the green “Code → Download ZIP” button instead:** it gives you a folder named
`VendorSearch-main`. Open it and copy the **`VendorSearch`** folder *from inside it* (not the outer
`-main` one) into `Interface\AddOns\`. The folder sitting in `AddOns\` must be named exactly
**`VendorSearch`**, or the game won't list the addon.

## Usage

Open any vendor and the **Find:** box + stat dropdown appear beneath the window.

- Type in the box to filter by name; the stat dropdown ticks multiple stats (menu stays open).
- `Esc` clears the box. Filters auto-reset when you open/close a vendor. The Buyback tab is
  untouched.
- `/vsearch clear` clears filters manually.

## How it works (safety)

Like the Auction House, the merchant indexes items by slot, so filtering the visible list can't be
allowed to change which slot a purchase hits. Vendor Search renders the filtered list through
remapped read-only getters, then re-stamps each visible button's ID with the **real** vendor index
before you can click it — and every stock buy / pickup / stack-split / tooltip path routes through
that button ID. It's verified against the stock 3.3.5 UI source and an offline test suite, so a
purchase always buys the item you're looking at. If a filtered redraw ever errors, the addon
disables itself for the session and the merchant reverts to stock behavior.

## License & disclaimer

Free and unofficial, released under the **MIT License** (see `LICENSE`). A fan-made World of
Warcraft addon for the Ascension private server — not affiliated with, endorsed by, or sponsored
by Blizzard Entertainment, Inc. or Project Ascension. World of Warcraft and Blizzard Entertainment
are trademarks of Blizzard Entertainment, Inc. No copyrighted game assets are included; the addon
only uses the game client's public Lua API.
