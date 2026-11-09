import Foundation

@MainActor
public final class RuntimeTurns<Runtime: Sendable> {
  public typealias Turn = Int

  public private(set) var turn: Turn = 0
  private var opening: Task<Runtime?, Never>?
  private var closing: Task<Void, Never>?

  public init() {}

  public var isOpening: Bool { opening != nil }

  public func isCurrent(_ candidate: Turn) -> Bool { candidate == turn }

  public func opened() async -> Runtime? {
    guard let opening else { return nil }
    return await opening.value
  }

  public func open(_ body: @escaping @MainActor (Turn) async -> Runtime?) {
    turn += 1
    let mine = turn
    let earlier = closing
    opening = Task {
      await earlier?.value
      return await body(mine)
    }
  }

  public func finishOpening(_ candidate: Turn) {
    if candidate == turn { opening = nil }
  }

  public func close(_ runtime: Runtime?, using close: @escaping @Sendable (Runtime) async -> Void) async {
    turn += 1
    let leftBehind = opening
    leftBehind?.cancel()
    opening = nil
    if runtime != nil || leftBehind != nil {
      let earlier = closing
      closing = Task {
        await earlier?.value
        _ = await leftBehind?.value
        if let runtime { await close(runtime) }
      }
    }
    await closing?.value
  }
}
