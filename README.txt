Armor DR Compare (Octo) v1.3.0
==========================

Ported for OctoWoW (private vanilla 1.12.1 server, TurtleWoW-based).
Originally targeted:
- WoW Classic Era / Hardcore 1.15.9
- WoW Burning Crusade Classic Anniversary 2.5.6

INSTALL
-------
Delete the old ArmorDRCompare-Octo folder first.

Extract this ZIP so the files are exactly here:

World of Warcraft\Interface\AddOns\ArmorDRCompare-Octo\ArmorDRCompare-Octo.toc

Then /reload or restart the game.

WHAT IT DOES
------------
Armor DR Compare adds the actual percentage-point change in physical damage
reduction next to Blizzard's Armor comparison.

On OctoWoW (vanilla 1.12.1), item comparison tooltips show absolute Armor
values (e.g. "145 Armor") rather than signed deltas, so the addon reads the
absolute Armor value from both the hovered item and the equipped item and
computes the difference itself.

Examples:

    +25 Armor (+0.16% DR)

or, if Blizzard formats it this way:

    119 Armor (+25) (+0.16% DR)

Only the signed percentage number uses Blizzard's green/red comparison color.
The parentheses and "DR" retain the normal tooltip text color.

DRUID CALCULATION
-----------------
The starting armor is always the player's live effective armor from
UnitArmor("player"), so the current form is already reflected.

For the prospective item, the raw comparison is separated into:

1. Intrinsic armor belonging to the item itself.
2. Any remaining Armor difference, such as an external item modification.

Only the intrinsic portion receives the active item-armor multiplier:

- Bear Form: 2.8x
- Dire Bear Form: 4.6x
- Moonkin Form: 4.6x
- Thick Hide: 1.02x to 1.10x, multiplied with the form bonus

FORMULA
-------
The attacker is assumed to be the same level as the player.

    DR = Armor / (Armor + 400 + 85 * attackerLevel)

The normal 75% armor mitigation cap is applied.

SUPPORTED COMPARISONS
---------------------
The addon processes:
- GameTooltip (the hovered item)
- ShoppingTooltip1 and ShoppingTooltip2
- ItemRefTooltip

This includes normal inventory comparisons and profession recipe outputs that
use the standard comparison system, as well as ShaguTweaks' equip-compare
tooltip polling.

COMMANDS
--------
/adrc

Shows current effective armor and same-level physical mitigation.

/adrc 100

Shows the DR change from +100 effective armor. This diagnostic amount is not
treated as item armor and is not multiplied by Druid forms.

/adrc status

Shows addon/client/build information, the current Druid item-armor multiplier,
and confirms the comparison hooks exist.

/adrc dump

Keep the mouse over the compared item and run this command. It prints every
visible line from GameTooltip, ShoppingTooltip1, ShoppingTooltip2, and
ItemRefTooltip for troubleshooting.
