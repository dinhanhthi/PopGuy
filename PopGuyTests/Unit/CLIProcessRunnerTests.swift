// CLIProcessRunnerTests.swift
// PopGuyTests
//
// Tests CLIProcessRunner — the shared subprocess streamer for CLI-based providers.
// Uses real system binaries (/bin/sh, /bin/cat, /usr/bin/false) so no mocking is
// needed; these are stable on all macOS versions this project targets (13.0+).

import Foundation
import Testing
@testable import PopGuy

@Suite("CLIProcessRunner")
struct CLIProcessRunnerTests {

    // MARK: - (a) Missing binary → ProviderError.transport

    @Test("missing binary finishes throwing transport error")
    func missingBinaryThrowsTransport() async throws {
        var thrownError: Error?
        do {
            let stream = CLIProcessRunner.run(
                executablePath: "/nonexistent",
                arguments: []
            )
            for try await _ in stream {}
        } catch {
            thrownError = error
        }
        guard let err = thrownError as? ProviderError,
              case .transport = err else {
            Issue.record("Expected ProviderError.transport, got: \(String(describing: thrownError))")
            return
        }
    }

    // MARK: - (b) Non-zero exit → ProviderError.httpError with exit code

    @Test("non-zero exit finishes throwing httpError with exit code")
    func nonZeroExitThrowsHttpError() async throws {
        var thrownError: Error?
        do {
            let stream = CLIProcessRunner.run(
                executablePath: "/usr/bin/false",
                arguments: []
            )
            for try await _ in stream {}
        } catch {
            thrownError = error
        }
        guard let err = thrownError as? ProviderError,
              case let .httpError(statusCode, _) = err else {
            Issue.record("Expected ProviderError.httpError, got: \(String(describing: thrownError))")
            return
        }
        #expect(statusCode != 0)
    }

    // MARK: - (c) Stdout line yielding + multibyte UTF-8 via /bin/cat

    @Test("stdout lines are yielded; multibyte UTF-8 round-trips correctly")
    func stdoutLinesAndMultibyteUTF8() async throws {
        // Two lines: ASCII and a multibyte Vietnamese string.
        // /bin/cat echoes stdin back to stdout; we send two newline-terminated lines.
        let input = "hello\nxin chào thế giới\n"
        var lines: [String] = []
        let stream = CLIProcessRunner.run(
            executablePath: "/bin/cat",
            arguments: [],
            stdin: input
        )
        for try await line in stream {
            lines.append(line)
        }
        #expect(lines == ["hello", "xin chào thế giới"])
    }

    // MARK: - (d) No-trailing-newline final line is still yielded

    @Test("final line without trailing newline is still yielded")
    func noTrailingNewlineIsYielded() async throws {
        // printf via /bin/sh -c emits "abc" with no trailing newline.
        var lines: [String] = []
        let stream = CLIProcessRunner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'abc'"]
        )
        for try await line in stream {
            lines.append(line)
        }
        #expect(lines == ["abc"])
    }

    // MARK: - (e) Cancellation mid-run does not double-resume / crash

    @Test("cancelling mid-run does not crash or double-resume")
    func cancelMidRunNoCrash() async throws {
        // /bin/sh -c 'while true; do echo x; done' produces infinite output.
        // We consume one token then break; the stream must finish cleanly.
        let stream = CLIProcessRunner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "while true; do echo x; sleep 0.05; done"]
        )
        var count = 0
        do {
            for try await _ in stream {
                count += 1
                if count >= 1 { break }
            }
        } catch {
            // A transport / cancellation error is acceptable here; what must
            // not happen is a crash or a double-resume panic.
        }
        // If we reach here without crashing, the test passes.
        #expect(count >= 1)
    }
}
