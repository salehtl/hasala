// HasalaKeychain (Keychain/): the adapter target behind CoreStore's SecretStore (spec 04 §4.4).
// Layer A like HasalaModel: Security is not importable in L0-L4 (§2.3), the app links this
// target from its Platform layer, and nothing in the core depends on it.
