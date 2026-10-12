# Free reward menu

The approved free base items are Daily Go, Greek Yogurt with Fruit Coulis, and Protein Crepes (all flavours). Daily Tropical, Daily Classic, coffee, Granola Delight, Sundae/Saturdae, ice cream, bundles, and standalone toppings are excluded. Added toppings remain chargeable; redemption still discounts only one base item.

The backend shares one policy between catalogue eligibility and quote/checkout enforcement. Existing unused reward QR tokens continue to work. Available rewards display the current menu without rewriting their issued benefit snapshots or redeemed history.

The iOS reward picker uses eligible IDs from the current POS catalogue rather than old eligibility flags stored on cart lines. This allows new eligible products and excludes removed products after catalogue refresh. Staff-facing reward instructions describe the updated menu.

Deploy the backend and rebuild the iOS app. Refresh the POS catalogue after deployment. No database migration or seeding is required.
