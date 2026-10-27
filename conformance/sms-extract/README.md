# conformance/sms-extract

Synthetic bank texts through the reading order of `docs/decisions/bank-texts.md`: the set-up
test, the never-a-payment drops (one-time codes and declined payments), the SMS templates, the
notice drops (card notices, registrations, service tickets, promotions) and the payment shape
for each kind of sender.

This set is a golden file. The Swift test `CoreMailboxTests` `SMSExtractGoldenTests/golden`
owns `expect`:

```sh
HASALA_UPDATE_GOLDEN=1 swift test --package-path ios/HasalaCore --filter SMSExtractGoldenTests
swift test --package-path ios/HasalaCore --filter SMSExtractGoldenTests
```

Every file here is named `synthetic-*` (the fence in `scripts/check.sh` refuses any other
name). Real texts are only in the private fixtures repository.
