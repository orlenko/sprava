@testable import Brains
import Darwin
import Foundation
import Testing

@Suite struct MCPShimOutputTests {
    @Test func aHostThatStopsReadingCannotHoldTheShimForever() throws {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        defer { fds.forEach { close($0) } }
        let flags = fcntl(fds[1], F_GETFL)
        let began = ProcessInfo.processInfo.systemUptime
        // More than the pipe holds, with its reader left open but never reading.
        #expect(!MCPShimConnection.writeOutput(fds[1], bytes: [UInt8](repeating: 0x61, count: 1 << 20), timeout: 0.05))
        #expect(ProcessInfo.processInfo.systemUptime - began < 1)
        #expect(fcntl(fds[1], F_GETFL) & O_NONBLOCK == flags & O_NONBLOCK)
    }

    @Test func anOrdinaryReplyIsDeliveredUnchanged() throws {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        defer { fds.forEach { close($0) } }
        let bytes = Array("invented reply\n".utf8)
        #expect(MCPShimConnection.writeOutput(fds[1], bytes: bytes, timeout: 1))
        var readBack = [UInt8](repeating: 0, count: bytes.count)
        #expect(read(fds[0], &readBack, readBack.count) == bytes.count)
        #expect(readBack == bytes)
    }

    @Test func aStartupFailureBoundsAnUnfinishedRequestWithStdinStillOpen() throws {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        defer { fds.forEach { close($0) } }
        let partial = Array(#"{"jsonrpc":"2.0","id":7"#.utf8)
        #expect(partial.withUnsafeBytes { write(fds[1], $0.baseAddress!, $0.count) } == partial.count)
        let began = ProcessInfo.processInfo.systemUptime
        #expect(MCPShimConnection.failureReply("invented startup failure", from: fds[0], timeout: 0.05) == nil)
        #expect(ProcessInfo.processInfo.systemUptime - began < 1)
    }
}
