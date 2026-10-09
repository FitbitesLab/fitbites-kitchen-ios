"""Execute the production QR token parser and domain migration using Swift."""
from pathlib import Path
import os, subprocess, tempfile
source = (Path(__file__).parents[1] / 'FitbitesKitchen/ContentView.swift').read_text()
def block(marker):
    start = source.index(marker)
    pos = source.index('{', start)
    depth = 1
    end = pos + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
program = 'import Foundation\n' + block('private enum POSRewardQRToken') + '\n' + block('private enum KitchenConnectionDefaults') + '''
@main struct Tests {
    @MainActor static func main() {
        let valid = "mfb-reward-v1." + String(repeating: "aZ9", count: 16)
        assert(POSRewardQRToken.normalized(valid) == valid)
        assert(POSRewardQRToken.normalized("  \\n" + valid + "\\n") == valid)
        for invalid in ["", "https://fitbites.com.vn", "mfb-reward-v1.", valid + "x", String(valid.dropLast()),
                        "mfb-reward-v1." + String(repeating: "é", count: 24),
                        "mfb-reward-v1." + String(repeating: "!", count: 48), valid + "\\nother"] {
            assert(POSRewardQRToken.normalized(invalid) == nil)
        }
        let production = "https://fitbites.com.vn"
        for old in ["https://app.fitbites.com.vn", "http://app.fitbites.com.vn", "  https://app.fitbites.com.vn  ", "", "http://127.0.0.1:8000"] {
            assert(KitchenConnectionDefaults.normalizedBaseURL(old) == production)
        }
        assert(KitchenConnectionDefaults.normalizedBaseURL(production) == production)
        assert(KitchenConnectionDefaults.normalizedBaseURL("https://app.fitbites.com.vn/") == production + "/")
        assert(KitchenConnectionDefaults.normalizedBaseURL("https://staging.fitbites.com.vn") == "https://staging.fitbites.com.vn")
        assert(KitchenConnectionDefaults.normalizedBaseURL("https://app.fitbites.com.vn.example.org") == "https://app.fitbites.com.vn.example.org")
        print("PASS: reward QR validation and exact-host production URL migration")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='pos-reward-tests-') as tmp:
    root = Path(tmp)
    (root/'test.swift').write_text(program)
    env = {**os.environ, 'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'}
    subprocess.run(['/usr/bin/xcrun','swiftc','-parse-as-library','-module-cache-path',str(root/'cache'),str(root/'test.swift'),'-o',str(root/'test')],env=env,check=True)
    subprocess.run([str(root/'test')],check=True)
