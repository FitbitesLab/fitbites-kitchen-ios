# Reward checkout usability safeguards

The server reward preview remains mandatory and the sale still requires an explicit staff confirmation. This change automates only the existing preview request after a scan or a change to its inputs, with a short debounce. When no preview is available, the footer offers REVIEW REWARD TOTAL instead of a Complete action that only reports a hidden prerequisite.

Preview failures, customer/item selection requirements and sale-submission failures are shown beside the footer action. Tapping the already-selected payment method, source or reward item does not discard the current preview. Changing payment preserves the chosen reward item. A sole eligible item replaces a stale selection referencing a removed cart line. Staff must still choose the rewarded item in a cart with multiple eligible lines.

A request revision and session check discard cancelled, invalidated or out-of-order preview responses. The completion action is unavailable during scanning, previewing or submission. Previewing never submits a sale automatically.

No backend, website, configuration, expiry, eligibility, pricing, tax, inventory, or redemption rules changed. The sale submission method, payable-total calculation, eligibility filter and customer selection method were verified byte-for-byte unchanged.

Validation: signed iOS build; executable Swift regression tests for delayed/out-of-order replies, cancellation, session replacement, identifier preservation, and missing reservations; 34 backend reward tests / 159 assertions. Existing unrelated local changes were preserved and excluded from this commit.
