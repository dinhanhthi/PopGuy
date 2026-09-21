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

    @Test("7 principal + 6 overflow is layout-capped at 6 + 5")
    func capsZones() {
        #expect(principal.count == 7)
        #expect(overflow.count == 6)
        let result = ToolbarController.allocate(
            principal: principal,
            overflow: overflow,
            maxPrincipal: 6,
            maxBurger: 5
        )
        #expect(result.principal.count == 6)
        #expect(result.overflow.count == 5)
    }

    @Test("principal shorter than maxPrincipal is kept in full; overflow still capped")
    func shortPrincipalKeepsAll() {
        let smallPrincipal: [ActionIdentifier] = [.builtin(.improve), .builtin(.shorten)]
        let result = ToolbarController.allocate(
            principal: smallPrincipal,
            overflow: overflow,
            maxPrincipal: 6,
            maxBurger: 5
        )
        #expect(result.principal.count == 2)
        #expect(result.overflow.count == 5)
    }

    @Test("Empty overflow yields empty burger list")
    func emptyOverflow() {
        let result = ToolbarController.allocate(
            principal: principal,
            overflow: [],
            maxPrincipal: 6,
            maxBurger: 5
        )
        #expect(result.overflow.isEmpty)
        #expect(result.principal.count == 6)
    }
}
