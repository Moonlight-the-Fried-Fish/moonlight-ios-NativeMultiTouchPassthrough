import ExternalAccessory
import Foundation
import GameController
import UIKit

/// Verified on RZ06-0547 firmware 1.01.000 using com.razer.kishicontrollerv2.
/// Uses legacy two-motor commands, not Apple's GCController haptics engine.
@objcMembers
final class KishiV3ProXLRumbler: NSObject, StreamDelegate {
    private static let accessoryProtocol = "com.razer.kishicontrollerv2"
    private var session: EASession?
    private var packet: Data?
    private var offset = 0
    private var queued: Data?
    private var lastSent: Data?
    private var transaction: UInt8 = 0x17
    private var active = true
    private var stopping = false
    private var closeTimer: Timer?
    private var incoming = Data()
    // Bound the cross-thread queue to one latest request, too.
    private let lock = NSLock()
    private var latest: (UInt16, UInt16)?
    private var deliveryScheduled = false
    private var invalidated = false

    override init() {
        super.init()
        active = UIApplication.shared.applicationState == .active
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(resignActive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(becomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(disconnected(_:)), name: .EAAccessoryDidDisconnect, object: nil)
        center.addObserver(self, selector: #selector(connected), name: .EAAccessoryDidConnect, object: nil)
        EAAccessoryManager.shared().registerForLocalNotifications()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func isTargetController(_ controller: GCController) -> Bool {
        controller.vendorName?.caseInsensitiveCompare("Razer Kishi V3 Pro XL") == .orderedSame
    }

    private func accessory() -> EAAccessory? {
        let matches = EAAccessoryManager.shared().connectedAccessories.filter {
            $0.isConnected && $0.modelNumber == "RZ06-0547" &&
            $0.manufacturer.caseInsensitiveCompare("Razer") == .orderedSame &&
            $0.protocolStrings.contains(Self.accessoryProtocol)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    @objc(setLowFrequencyMotor:highFrequencyMotor:)
    func setLowFrequencyMotor(_ low: UInt16, highFrequencyMotor high: UInt16) {
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        latest = (low, high)
        let schedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.async { [self] in
                lock.lock()
                let value = invalidated ? nil : latest
                latest = nil
                deliveryScheduled = false
                lock.unlock()
                guard active, !stopping, let value else { return }
                let data = Self.motorPayload(low: value.0, high: value.1)
                if data == lastSent && queued == nil && packet == nil { return }
                queued = data
                if openSession() { flush() }
            }
        }
    }

    /// 7 zero bits + 8 zero bits + left8 + right8 + padding bit,
    /// wrapped as Nexus chunk 1 with 64 data bytes. Stop is both zero.
    static func motorPayload(low: UInt16, high: UInt16) -> Data {
        let left = UInt8((UInt32(low) * 255 + 32767) / 65535)
        let right = UInt8((UInt32(high) * 255 + 32767) / 65535)
        return Data([1, 0, left >> 7, (left << 1) | (right >> 7), right << 1] + [UInt8](repeating: 0, count: 60))
    }

    static func frame(payload: Data, transaction: UInt8) -> Data {
        precondition(payload.count == 65)
        var bytes: [UInt8] = [0, transaction, 0, 75, 0, 65, 0x16, 0x0E]
        bytes += payload
        bytes += [bytes.dropFirst(2).reduce(0, ^), 0]
        return Data(bytes)
    }

    private func openSession() -> Bool {
        if session != nil { return true }
        guard let device = accessory(),
              let created = EASession(accessory: device, forProtocol: Self.accessoryProtocol),
              let input = created.inputStream, let output = created.outputStream else { return false }
        session = created
        NSLog("[KishiRumble] opening %@", device.name)
        for stream in [input as Stream, output as Stream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .common)
            stream.open()
        }
        return true
    }

    private func flush() {
        guard let output = session?.outputStream, output.streamStatus == .open else { return }
        while output.hasSpaceAvailable {
            if packet == nil {
                guard let data = queued else {
                    if stopping { closeSession() }
                    return
                }
                queued = nil
                transaction &+= 1
                packet = Self.frame(payload: data, transaction: transaction)
                offset = 0
            }
            guard let bytes = packet else { return }
            let written = bytes.withUnsafeBytes {
                output.write($0.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), maxLength: bytes.count - offset)
            }
            if written < 0 {
                NSLog("[KishiRumble] write error: %@", String(describing: output.streamError))
                closeSession()
                return
            }
            if written == 0 { return }
            offset += written
            if offset == bytes.count {
                lastSent = bytes.subdata(in: 8..<73)
                packet = nil
                offset = 0
            }
        }
        if stopping && packet == nil && queued == nil { closeSession() }
    }

    func stopAndClose() {
        // Retain until the stop has had a chance to reach the stream.
        DispatchQueue.main.async { [self] in
            lock.lock(); latest = nil; lock.unlock()
            guard session != nil else { return }
            stopping = true
            queued = Self.motorPayload(low: 0, high: 0)
            closeTimer?.invalidate()
            closeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [self] _ in
                if packet != nil || queued != nil { NSLog("[KishiRumble] stop write incomplete before close") }
                closeSession()
            }
            flush()
        }
    }

    func invalidate() {
        lock.lock(); invalidated = true; latest = nil; lock.unlock()
        stopAndClose()
    }

    @objc private func resignActive() { active = false; stopAndClose() }
    @objc private func becomeActive() { active = true }
    @objc private func connected() {
        // GCController can arrive before ExternalAccessory. Retry only the latest
        // request received while waiting, never rumble saved from a disconnection.
        guard active, !stopping, queued != nil else { return }
        lock.lock(); let allowed = !invalidated; lock.unlock()
        if allowed && openSession() { flush() }
    }

    @objc private func disconnected(_ notification: Notification) {
        guard let device = notification.userInfo?[EAAccessoryKey] as? EAAccessory,
              device.connectionID == session?.accessory?.connectionID else { return }
        closeSession()
    }

    private func closeSession() {
        closeTimer?.invalidate(); closeTimer = nil
        if let session {
            for stream in [session.inputStream as Stream?, session.outputStream as Stream?].compactMap({ $0 }) {
                stream.close(); stream.remove(from: .main, forMode: .common); stream.delegate = nil
            }
        }
        session = nil; packet = nil; queued = nil; lastSent = nil
        incoming.removeAll(); offset = 0; stopping = false
    }

    func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        guard let session, stream === session.inputStream || stream === session.outputStream else { return }
        switch eventCode {
        case .openCompleted, .hasSpaceAvailable: flush()
        case .hasBytesAvailable:
            guard let input = session.inputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 512)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count < 0 { closeSession(); return }
                if count == 0 { break }
                incoming.append(contentsOf: buffer.prefix(count))
                if incoming.count > 8192 { closeSession(); return }
            }
            // EA is a byte stream: replies may be fragmented or combined.
            while incoming.count >= 10 {
                let bytes = [UInt8](incoming)
                let length = Int(bytes[2]) * 256 + Int(bytes[3])
                guard length >= 10 && length <= 265 else { closeSession(); return }
                guard bytes.count >= length else { return }
                let reply = Array(bytes.prefix(length))
                if reply[0] != 2 || reply[6] != 0x16 || reply[7] != 0x0E ||
                    Int(reply[5]) != length - 10 || reply[length - 1] != 0 ||
                    reply[2..<length - 2].reduce(0, ^) != reply[length - 2] {
                    NSLog("[KishiRumble] rejected or malformed reply, status=%u", reply[0])
                    lastSent = nil
                }
                incoming.removeFirst(length)
            }
        case .errorOccurred, .endEncountered: stopAndClose()
        default: break
        }
    }
}
