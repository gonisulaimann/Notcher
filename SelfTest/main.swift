import CryptoKit
import Dispatch
import Foundation
import LinkCore

// Minimal self-test harness for LinkCore: crypto, codec framing, and a live
// loopback handshake + encrypted exchange between two transports.
// Exit code is nonzero on any failure. Run: `swift run LinkSelfTest`

// Top-level entry ON PURPOSE (no @main struct): @main codegen can route
// through swift_task_asyncMainDrainQueue, which may exit(0) a harness whose
// queues look momentarily empty. Classic main + dispatchMain owns lifetime.
Task {
    await SelfTest.run()
    print(SelfTest.failures == 0 ? "ALL SELF-TESTS PASSED" : "\(SelfTest.failures) SELF-TEST(S) FAILED")
    fflush(stdout)
    exit(SelfTest.failures == 0 ? 0 : 1)
}
dispatchMain()

struct SelfTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ cond: Bool, _ name: String) {
        if cond { print("PASS  \(name)") } else { print("FAIL  \(name)"); failures += 1 }
    }

    static func run() async {
        // 1. AES-GCM round trip.
        do {
            let key = LinkCrypto.deriveKey(salt: "s", code: "123456")
            let sealed = try LinkCrypto.seal(Data("hello notch".utf8), key: key)
            let opened = try LinkCrypto.open(sealed, key: key)
            check(opened == Data("hello notch".utf8), "crypto round trip")
        } catch {
            check(false, "crypto round trip (\(error))")
        }

        // 2. Wrong pairing code must not decrypt.
        do {
            let a = LinkCrypto.deriveKey(salt: "s", code: "123456")
            let b = LinkCrypto.deriveKey(salt: "s", code: "654321")
            let sealed = try LinkCrypto.seal(Data("x".utf8), key: a)
            var rejected = false
            do { _ = try LinkCrypto.open(sealed, key: b) } catch { rejected = true }
            check(rejected, "wrong code rejected")
        } catch {
            check(false, "wrong code rejected (\(error))")
        }

        // 3. Codec framing.
        do {
            var m = LinkMessage(kind: .textPush, deviceName: "iPhone", deviceID: "abc")
            m.text = "Send this to the Mac"
            let payload = try LinkCodec.encode(m)
            let frame = LinkCodec.frame(payload)
            let len = LinkCodec.readLength(frame.prefix(4))
            let back = try LinkCodec.decode(Data(frame.dropFirst(4)))
            check(frame.count == payload.count + 4 && Int(len) == payload.count && back == m, "codec framing")
        } catch {
            check(false, "codec framing (\(error))")
        }

        // 4. Live loopback: handshake + encrypted message + peer presence.
        do {
            let host = LinkTransport(deviceName: "Mac", deviceID: "mac-1", code: { "248163" },
                                     callbackQueue: DispatchQueue(label: "t1"))
            let peer = LinkTransport(deviceName: "iPhone", deviceID: "phone-1", code: { "248163" },
                                     callbackQueue: DispatchQueue(label: "t2"))
            defer { host.stop(); peer.stop() }
            let port = try host.listenDirect()
            final class Box: @unchecked Sendable {
                var hello = false
                var text: String?
            }
            let box = Box()
            // Note: textPush flows peer -> host, so the HOST must record it.
            host.onMessage = { msg in
                if msg.kind == .hello { box.hello = true }
                if msg.kind == .textPush { box.text = msg.text }
            }
            peer.connectDirect(port: port)
            var ok = false
            for _ in 0 ..< 50 {
                try await Task.sleep(for: .milliseconds(100))
                if box.hello { ok = true; break }
            }
            check(ok, "loopback handshake (hello)")
            var t = LinkMessage(kind: .textPush, deviceName: "iPhone", deviceID: "phone-1")
            t.text = "ping"
            peer.broadcast(t)
            var ok2 = false
            for _ in 0 ..< 50 {
                try await Task.sleep(for: .milliseconds(100))
                if box.text == "ping" { ok2 = true; break }
            }
            check(ok2, "loopback encrypted message")
            check(host.connectedPeers.map(\.deviceID).contains("phone-1"), "loopback peer presence")
        } catch {
            check(false, "loopback (\(error))")
        }

        // 5. Chunker: offer + chunks + done reassemble to the original bytes.
        do {
            var bytes = Data(count: 100 * 1024)
            for i in bytes.indices { bytes[i] = UInt8(i & 0xFF) }
            let msgs = LinkChunker.pack(data: bytes, fileName: "a.bin",
                                        deviceName: "d", deviceID: "id")
            let offer = msgs.first, done = msgs.last
            var re = Data()
            for m in msgs where m.kind == .fileChunk {
                re.append(Data(base64Encoded: m.base64 ?? "") ?? Data())
            }
            check(msgs.count == 2 + 4
                && offer?.kind == .fileOffer && offer?.fileSize == bytes.count
                && done?.kind == .fileDone && re == bytes,
                "chunker pack/reassemble")
        }

        // 6. Wrong-code peer must never authenticate.
        do {
            let host = LinkTransport(deviceName: "Mac", deviceID: "mac-1", code: { "111111" },
                                     callbackQueue: DispatchQueue(label: "t3"))
            let eve = LinkTransport(deviceName: "Eve", deviceID: "eve-1", code: { "999999" },
                                    callbackQueue: DispatchQueue(label: "t4"))
            defer { host.stop(); eve.stop() }
            let port = try host.listenDirect()
            eve.connectDirect(port: port)
            try await Task.sleep(for: .seconds(2))
            check(host.connectedPeers.isEmpty, "wrong-code peer rejected")
        } catch {
            check(false, "wrong-code peer rejected (\(error))")
        }
    }
}
