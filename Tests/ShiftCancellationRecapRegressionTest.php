<?php

use App\Models\Sale;
use App\Models\User;
use App\Services\StaffShiftService;

it('keeps current and closed drawer totals consistent after cancellation and deletion', function () {
    $staff = User::factory()->create(['role' => 'staff']);
    config(['services.kitchen_api.token' => 'shift-test-token', 'services.kitchen_api.device_user_id' => $staff->id]);
    $service = app(StaffShiftService::class);
    $shift = $service->startShift($staff, 500000);
    $service->recordCashMovement($staff, $shift, 'deposit', 100000, 'Change');
    $service->recordCashMovement($staff, $shift, 'withdrawal', 20000, 'Withdrawal');

    $makeSale = fn ($amount, $method = 'cash') => Sale::create([
        'user_id' => $staff->id, 'staff_shift_id' => $shift->id,
        'subtotal' => $amount, 'total_amount' => $amount, 'discount' => 0,
        'payment_method' => $method, 'order_source' => 'pos', 'status' => 'preparing',
    ]);
    $makeSale(45000);
    $cancelled = $makeSale(90000);
    $deleted = $makeSale(135000);
    $makeSale(60000, 'qr');
    $this->withHeader('X-Kitchen-Token', 'shift-test-token')->getJson('/api/pos/shift')
        ->assertOk()->assertJsonPath('shift.recap.expected_cash', 850000);

    $cancelled->update(['status' => 'cancelled']);
    $deleted->delete();
    $this->getJson('/api/pos/recap')->assertOk()
        ->assertJsonPath('recap.summary.sales_total', 105000)
        ->assertJsonPath('recap.summary.orders_count', 2);
    $this->getJson('/api/pos/shift')->assertOk()
        ->assertJsonPath('shift.recap.cash_sales', 45000)
        ->assertJsonPath('shift.recap.expected_cash', 625000)
        ->assertJsonPath('shift.recap.revenue', 105000);
    $this->postJson('/api/pos/shift/end', ['closing_cash' => 625000])->assertOk();
    $closedRecap = $service->recapForShift($shift->fresh());
    expect($closedRecap['expected_cash'])->toBe(625000.0)
        ->and($closedRecap['difference'])->toBe(0.0);
});
