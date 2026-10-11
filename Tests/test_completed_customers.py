"""Verify completed-ticket customer fallback, loyalty decoding, and legacy cache compatibility."""
from pathlib import Path
import os
import subprocess
import tempfile

source = (Path(__file__).parents[1] / 'FitbitesKitchen/ContentView.swift').read_text()

def block(marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

program = r'''
import Foundation
extension String {
    var nilIfBlank: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
    var paymentDisplayText: String { self }
}
struct Source { let shortLabel = "STORE" }
struct Totals { let total: Double }
struct KitchenOrder {
    let id = 42; let orderNumber = "#42"; let source = Source()
    let customer: KitchenCustomer
    let paymentMethod: String? = "cash"; let notes: String? = nil
    let totals: Totals? = Totals(total: 55000); let items: [Int] = []
}
struct KitchenOnlineOrder {
    let customer: KitchenCustomer
    let fulfillmentMethod: String? = nil; let deliveryAddress: String? = nil
    let pickupTime: String? = nil; let paymentMethod: String? = nil; let notes: String? = nil
    let totals = Totals(total: 55000)
}
struct CompletedKitchenTicketItem: Codable, Equatable { init(item: Int) {} }
''' + block('struct KitchenCustomer:') + '\n' + block('struct CompletedKitchenTicket:') + r'''
func customer(_ json: String) throws -> KitchenCustomer {
    try JSONDecoder().decode(KitchenCustomer.self, from: Data(json.utf8))
}
func ticket(_ customer: KitchenCustomer, online: KitchenCustomer? = nil, previous: CompletedKitchenTicket? = nil) -> CompletedKitchenTicket {
    CompletedKitchenTicket(order: KitchenOrder(customer: customer), onlineDetails: online.map { KitchenOnlineOrder(customer: $0) }, archivedAt: Date(), previousTicket: previous)
}
let member = try customer(#"{"name":"  Minh Nguyen  ","phone":null,"loyalty_stamps":5,"loyalty_target":9}"#)
let memberTicket = ticket(member)
assert(memberTicket.customerName == "Minh Nguyen" && memberTicket.loyaltyStamps == 5 && memberTicket.loyaltyTarget == 9)
let guest = try customer(#"{"name":null,"phone":null}"#)
assert(ticket(guest).customerName == "Guest order" && ticket(guest).loyaltyStamps == nil)
let blank = try customer(#"{"name":"  ","phone":null}"#)
assert(ticket(blank, online: member).customerName == "Minh Nguyen")
assert(ticket(blank, previous: memberTicket).customerName == "Minh Nguyen")
assert(ticket(blank, previous: memberTicket).loyaltyStamps == 5)
let updated = try customer(#"{"name":"Linh","loyalty_stamps":0,"loyalty_target":9}"#)
assert(ticket(updated, previous: memberTicket).customerName == "Linh")
assert(ticket(updated, previous: memberTicket).loyaltyStamps == 0)
let data = try JSONEncoder().encode(memberTicket)
assert(try JSONDecoder().decode(CompletedKitchenTicket.self, from: data) == memberTicket)
var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
legacy.removeValue(forKey: "loyaltyStamps"); legacy.removeValue(forKey: "loyaltyTarget")
let legacyData = try JSONSerialization.data(withJSONObject: legacy)
let legacyTicket = try JSONDecoder().decode(CompletedKitchenTicket.self, from: legacyData)
assert(legacyTicket.customerName == "Minh Nguyen" && legacyTicket.loyaltyStamps == nil)
print("PASS: customer fallback, current and zero stamp balances, guests, cache round trip, legacy cache")
'''
# Swift assert uses a nonthrowing autoclosure.
program = program.replace('assert(try JSONDecoder().decode(CompletedKitchenTicket.self, from: data) == memberTicket)',
                          'let roundTrip = try JSONDecoder().decode(CompletedKitchenTicket.self, from: data)\nassert(roundTrip == memberTicket)')
with tempfile.TemporaryDirectory(prefix='completed-customer-') as directory:
    path = Path(directory)
    (path / 'Regression.swift').write_text(program)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(path / 'cache'),
                    str(path / 'Regression.swift'), '-o', str(path / 'regression')], check=True, env=env)
    subprocess.run([str(path / 'regression')], check=True)
