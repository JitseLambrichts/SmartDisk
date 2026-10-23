import Foundation
import Testing
@testable import SmartDisk

struct SlimClientTests {
    @Test(.timeLimit(.minutes(1)))
    func drainsDiagnosticsWithoutBlockingOutput() async throws {
        let client = SlimClient(binary: URL(fileURLWithPath: "/bin/sh"))
        let output = try await client.run(["-c", "head -c 262144 /dev/zero >&2; printf complete"])
        #expect(String(data: output, encoding: .utf8) == "complete")
    }

    @Test
    func exposesCommandFailures() async {
        let client = SlimClient(binary: URL(fileURLWithPath: "/bin/sh"))
        do {
            _ = try await client.run(["-c", "printf 'Example failure' >&2; exit 9"])
            Issue.record("Expected the bundled command failure to reach the app")
        } catch {
            #expect(error.localizedDescription == "Example failure")
        }
    }
}
