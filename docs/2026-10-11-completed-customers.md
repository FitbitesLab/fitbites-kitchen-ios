# Completed sales: customer name and loyalty stamps

Kitchen's completed sales cards now display the customer name beneath the order number, followed by loyalty stars and an explicit stamp count for linked customers. The receipt detail shows the same customer and balance. Guest orders show `Guest order` without a loyalty row.

The Kitchen API exposes `customer.loyalty_stamps` and `customer.loyalty_target` in detailed tickets. It eagerly loads loyalty cards and reads the current balance; opening the report does not award stamps or modify customer data. The displayed count is the customer's current balance at the latest report refresh, not stamps earned by this particular sale.

Saved completed tickets retain the balance for offline use. Existing saved tickets and older API responses without loyalty fields continue to decode. Customer names fall back to online details and then the saved name when refresh data is blank.

Backend changes are in `fitbites-app/app/Services/Kitchen/KitchenService.php` and `KitchenOrderTransformer.php`. Deploy these alongside the rebuilt iOS app to enable stamp balances. No database migration is required.

Validation: `Tests/test_completed_customers.py` exercises name fallbacks, zero balances, guests, saved-ticket round trips, and legacy cache decoding. Backend KitchenCompletedOrdersTest and KitchenApiTest verify the report payload and that the report performs no writes.
