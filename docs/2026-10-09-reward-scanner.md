# Reward QR camera repair

The POS scanner previously attempted camera setup without an explicit permission flow, silently returned on setup failures, and started/stopped capture on different queues. It also defaulted to the retired app.fitbites.com.vn host.

The updated scanner requests video permission, provides a Settings recovery path for denied access, reports setup/runtime/interruption failures, resumes after Settings or interruptions, and serializes capture configuration/start/stop. Preview orientation tracks the interface orientation. It accepts only the server's mfb-reward-v1 token format and delivers one scan per presentation; unrelated QR codes leave scanning active. The scan endpoint and server-authoritative reservation/quote/checkout behavior are unchanged. Camera usage description was already configured for Debug and Release.

The POS base URL now defaults to fitbites.com.vn and migrates only the exact old app.fitbites.com.vn hostname, retaining custom hosts. Print bridge settings are outside this change.

Validation: simulator build; signed physical iOS build; production Swift token parser and exact-host migration tests; 34 backend reward lifecycle/manual issuance tests (159 assertions). The signed build was installed successfully on the selected Fitbites iPad. Physical camera permission and real QR scanning still require an on-device check.

Other pre-existing local checkout changes were preserved and excluded from this commit.
