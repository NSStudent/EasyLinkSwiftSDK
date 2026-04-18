import Foundation

actor ResponseRouter {
  typealias Predicate = @Sendable ([UInt8]) -> Bool

  private struct PendingResponse {
    var predicate: Predicate
    var continuation: CheckedContinuation<[UInt8], Error>
  }

  private var pendingResponses: [UUID: PendingResponse] = [:]
  private var bufferedResponses: [[UInt8]] = []

  func wait(
    matching predicate: @escaping Predicate,
    timeout: Duration = .seconds(3)
  ) async throws -> [UInt8] {
    try await withThrowingTaskGroup(of: [UInt8].self) { group in
      group.addTask {
        try await self.wait(matching: predicate)
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw EasyLinkError.timeout
      }

      guard let result = try await group.next() else {
        throw EasyLinkError.timeout
      }
      group.cancelAll()
      return result
    }
  }

  func receive(_ response: [UInt8]) {
    guard let match = pendingResponses.first(where: { $0.value.predicate(response) }) else {
      bufferedResponses.append(response)
      return
    }
    pendingResponses.removeValue(forKey: match.key)
    match.value.continuation.resume(returning: response)
  }

  private func wait(matching predicate: @escaping Predicate) async throws -> [UInt8] {
    if let index = bufferedResponses.firstIndex(where: predicate) {
      return bufferedResponses.remove(at: index)
    }

    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pendingResponses[id] = PendingResponse(
          predicate: predicate,
          continuation: continuation
        )
      }
    } onCancel: {
      Task {
        await self.cancel(id)
      }
    }
  }

  private func cancel(_ id: UUID) {
    guard let pending = pendingResponses.removeValue(forKey: id) else {
      return
    }
    pending.continuation.resume(throwing: CancellationError())
  }
}
