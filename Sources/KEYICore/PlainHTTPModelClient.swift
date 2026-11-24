import Foundation
import KEYIHTTP

/// Only the explicitly configured HTTP Endpoint uses this transport. HTTPS
/// requests keep URLSession and the application's default ATS policy.
enum PlainHTTPModelClient {
    static func post(
        to url: URL, apiKey: String, body: Data, timeout: TimeInterval
    ) async throws -> (Data, Int) {
        guard !apiKey.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
            throw URLError(.userAuthenticationRequired)
        }
        let transfer = Transfer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try transfer.post(url: url, apiKey: apiKey, body: body, timeout: timeout)
                    })
                }
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    private final class Transfer: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.withLock { cancelled = true }
        }

        private var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        func post(url: URL, apiKey: String, body: Data, timeout: TimeInterval) throws -> (Data, Int) {
            var response = KEYIHTTPResponse()
            let result = body.withUnsafeBytes { bytes in
                KEYIHTTPPost(
                    url.absoluteString,
                    "Authorization: Bearer \(apiKey)",
                    bytes.baseAddress,
                    bytes.count,
                    Int(timeout * 1_000),
                    { context in
                        let transfer = Unmanaged<Transfer>.fromOpaque(context!).takeUnretainedValue()
                        return transfer.isCancelled ? 1 : 0
                    },
                    Unmanaged.passUnretained(self).toOpaque(),
                    &response
                )
            }
            let data = response.body.map {
                Data(bytesNoCopy: $0, count: response.length, deallocator: .free)
            } ?? Data()
            if isCancelled { throw CancellationError() }
            guard result == 0 else {
                if KEYIHTTPErrorIsTimeout(result) != 0 { throw URLError(.timedOut) }
                throw URLError(.badServerResponse, userInfo: [
                    NSLocalizedDescriptionKey: String(cString: KEYIHTTPErrorDescription(result))
                ])
            }
            return (data, response.status)
        }
    }
}
