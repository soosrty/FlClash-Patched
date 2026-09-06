import Foundation
import os

final class NECoreEventQueue {
  private let sharedStateStore: PacketTunnelSharedStateStore
  private let eventQueueDirectoryName = "core-events"
  private let maxEventQueueFiles = 10
  private let logger = Logger(
    subsystem: PacketTunnelEnvironment.extensionBundleIdentifier,
    category: "NECoreEventQueue"
  )

  private var eventsSincePrune = 0
  private var coreActive = true
  // Events arrive on the core callback thread while diagnostics are recorded
  // from the memory sampler's queue, so the queue state needs a lock.
  private let lock = NSLock()

  init(sharedStateStore: PacketTunnelSharedStateStore) {
    self.sharedStateStore = sharedStateStore
  }

  func start() {
    NECoreBridge.setEventListener { [weak self] event in
      guard let self,
        let event,
        !event.isEmpty
      else {
        return
      }
      self.enqueue(event)
    }
  }

  func stop() {
    NECoreBridge.setEventListener(nil)
  }

  func markCoreResponsive() {
    lock.lock()
    coreActive = true
    lock.unlock()
  }

  /// Publishes a log line as if the core had emitted it, so the reason a tunnel
  /// went down reaches the app log instead of only os_log. The queue is backed
  /// by files in the app group, so a record written here survives the extension
  /// being terminated and is drained on the next app launch.
  func recordDiagnostic(_ message: String, level: String = "info") {
    let payload: [String: Any] = [
      "method": "message",
      "arguments": [
        [
          "type": "log",
          "data": [
            "LogLevel": level,
            "source": "core",
            "Payload": "[NE] \(message)",
          ],
        ],
      ],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
      return
    }
    // A diagnostic is the one event worth keeping when backpressure is on: it
    // explains the shutdown that the dropped events would have described.
    enqueue(data, forceActive: true)
  }

  /// Resident footprint of this extension. NE processes get a much smaller
  /// allowance than the host app, and jetsam kills without calling stopTunnel,
  /// so the last sample before the log ends is the evidence of an OOM kill.
  static func memoryFootprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return nil
    }
    return info.phys_footprint
  }

  /// - Parameter forceActive: keeps a diagnostic from being dropped by
  ///   backpressure. Passed as an argument rather than set by the caller so the
  ///   lock is never held across this call (NSLock is not recursive).
  private func enqueue(_ event: Data, forceActive: Bool = false) {
    guard let directory = eventQueueDirectory() else {
      logger.error("enqueue failed: missing app group dir")
      return
    }
    // The core callback thread and the memory monitor both reach this method, so
    // coreActive/eventsSincePrune need serializing.
    lock.lock()
    defer { lock.unlock() }
    if forceActive {
      coreActive = true
    }
    // Backpressure must not be a one-way latch. The old code only cleared
    // coreActive from markCoreResponsive(), so a startup burst (one event per
    // provider) silenced the event stream for the rest of the session and every
    // later log - including the reason a tunnel went down - was dropped.
    if !coreActive {
      guard eventFiles(in: directory).count < maxEventQueueFiles else {
        return
      }
      coreActive = true
      logger.info("enqueue resumed: event queue drained below cap")
    }
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
      let fileName = "\(timestamp)-\(UUID().uuidString)"
      let fileURL = directory.appendingPathComponent("\(fileName).json")
      let temporaryURL = directory.appendingPathComponent(".\(fileName).tmp")
      do {
        try event.write(to: temporaryURL)
        try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
      }
      eventsSincePrune += 1
      if eventsSincePrune >= maxEventQueueFiles {
        eventsSincePrune = 0
        prune(in: directory)
      }
      notifyEventAvailable()
    } catch {
      logger.error(
        "enqueue failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func prune(in directory: URL) {
    var files = eventFiles(in: directory)
    var overflowCount = files.count - maxEventQueueFiles
    if overflowCount > 0 {
      coreActive = false
      logger.warning(
        "prune overflow=\(overflowCount, privacy: .public), set core inactive"
      )
    }

    while overflowCount > 0 && !files.isEmpty {
      removeOldestEventFile(&files)
      overflowCount -= 1
    }
  }

  private func eventFiles(in directory: URL) -> [URL] {
    guard let fileURLs = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
      return []
    }
    return fileURLs.filter { fileURL in
      fileURL.pathExtension == "json" &&
        (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?
          .isRegularFile == true
    }.sorted { lhs, rhs in
      lhs.lastPathComponent < rhs.lastPathComponent
    }
  }

  private func removeOldestEventFile(_ files: inout [URL]) {
    let fileURL = files.removeFirst()
    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch {
      logger.warning(
        "prune failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func eventQueueDirectory() -> URL? {
    sharedStateStore.appGroupDirectory()?.appendingPathComponent(
      eventQueueDirectoryName,
      isDirectory: true
    )
  }

  private func notifyEventAvailable() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(
        PacketTunnelEnvironment.eventNotificationName as CFString
      ),
      nil,
      nil,
      true
    )
  }
}
