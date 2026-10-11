/// Keeps the last value derived from a key, so a view model runs its engine once per
/// ledger change (the store's `revision`) and input change, not once per read: a screen
/// reads its snapshot a dozen times in one redraw (spec 04 §18.3).
///
/// View models hold it `@ObservationIgnored`; reading the store's `revision` while
/// building the key is what Observation tracks.
struct Memo<Key: Equatable, Value> {
  private var last: (key: Key, value: Value)?

  mutating func value(for key: Key, _ make: () -> Value) -> Value {
    if let last, last.key == key { return last.value }
    let value = make()
    last = (key, value)
    return value
  }
}
