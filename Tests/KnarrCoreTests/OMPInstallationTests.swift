import Foundation
import Testing
@testable import KnarrCore

@Suite struct OMPInstallationTests {
    @Test func changedBinaryIsRejectedBeforeLaunch() throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        let binary = fixture.directory.appendingPathComponent("omp")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        #expect(throws: OMPRPCError.self) { try OMPInstallation(executable: binary) }
    }
}
