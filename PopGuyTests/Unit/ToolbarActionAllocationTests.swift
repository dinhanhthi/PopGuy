// ToolbarActionAllocationTests.swift
// PopGuyTests

import Foundation
import Testing
@testable import PopGuy

@Suite("Toolbar action allocation")
struct ToolbarActionAllocationTests {

    private let principal: [ActionIdentifier] = [
        .builtin(.improve), .builtin(.shorten), .builtin(.proofread),
        .builtin(.prompt), .builtin(.translate), .dictionary, .speak,
    ]
    private let overflow: [ActionIdentifier] = [
        .custom(UUID()), .custom(UUID()), .custom(UUID()),
        .custom(UUID()), .custom(UUID()), .custom(UUID()),
    ]

    @Test("Pro caps principal at 6 and overflow at 5")
    func proCapsZones() {
        let result = ToolbarController.allocate(
            principal: principal,
            overflow: overflow,
            isPro: true,
            freeMaxActive: 5,
            maxPrincipal: 6,
            maxBurger: 5
        )
        #expect(result.principal.count == 6)
        #expect(result.overflow.count == 5)
    }

    @Test("Free allocates principal-first within freeMaxActive")
    func freePrincipalFirst() {
        let result = ToolbarController.allocate(
            principal: principal,
            overflow: overflow,
            isPro: false,
            freeMaxActive: 5,
            maxPrincipal: 6,
            maxBurger: 5
        )
        #expect(result.principal.count == 5)
        #expect(result.overflow.count == 0)
    }

    @Test("Free leaves remainder for burger when principal is smaller than budget")
    func freeRemainderForBurger() {
        let smallPrincipal: [ActionIdentifier] = [.builtin(.improve), .builtin(.shorten)]
        let result = ToolbarController.allocate(
            principal: smallPrincipal,
            overflow: overflow,
            isPro: false,
            freeMaxActive: 5,
            maxPrincipal: 6,
            maxBurger: 5
        )
        #expect(result.principal.count == 2)
        #expect(result.overflow.count == 3)
    }

    @Test("Empty overflow yields empty burger list")
    func emptyOverflow() {
        let result = ToolbarController.allocate(
            principal: principal,
            overflow: [],
            isPro: true,
            freeMaxActive: 5,
            maxPrincipal: 6,
            maxBurger: 5
        )
        #expect(result.overflow.isEmpty)
    }
}
