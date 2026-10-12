"""Verify production reward selection uses refreshed catalogue IDs, not stale cart flags."""
from pathlib import Path
import os
import subprocess
import tempfile
source = (Path(__file__).parents[1] / 'FitbitesKitchen/ContentView.swift').read_text()
start = source.index('    private var eligibleRewardLines: [POSCartLine]')
end = source.index('\n    }', start) + len('\n    }')
selection = source[start:end].replace('private var', 'var', 1)
assert 'Daily Go, Daily Classic, or standard coffee' not in source
harness = '''import Foundation
struct Product { let id: Int; let freeRewardEligibility: String? }
struct POSCartLine { let id: String; let product: Product }
struct Picker {
 let lines: [POSCartLine]; let rewardEligibleProductIDs: Set<Int>
'''+selection+'''
}
let staleClassic = POSCartLine(id: "classic", product: Product(id: 10, freeRewardEligibility: "daily_reward"))
let oldCrepe = POSCartLine(id: "crepe", product: Product(id: 20, freeRewardEligibility: nil))
let ordinary = POSCartLine(id: "ordinary", product: Product(id: 30, freeRewardEligibility: nil))
let picker = Picker(lines: [staleClassic, oldCrepe, ordinary], rewardEligibleProductIDs: [20])
assert(picker.eligibleRewardLines.map(\\.id) == ["crepe"])
let empty = Picker(lines: [staleClassic, oldCrepe], rewardEligibleProductIDs: [])
assert(empty.eligibleRewardLines.isEmpty)
let refreshed = Picker(lines: [oldCrepe, ordinary], rewardEligibleProductIDs: [20, 30])
assert(refreshed.eligibleRewardLines.count == 2)
print("PASS: stale cart flags ignored; newly eligible catalogue IDs used; removed items excluded")
'''
with tempfile.TemporaryDirectory(prefix='reward-menu-') as directory:
 path=Path(directory);(path/'Regression.swift').write_text(harness)
 env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
 subprocess.run(['xcrun','swiftc','-module-cache-path',str(path/'cache'),str(path/'Regression.swift'),'-o',str(path/'regression')],check=True,env=env)
 subprocess.run([str(path/'regression')],check=True)
