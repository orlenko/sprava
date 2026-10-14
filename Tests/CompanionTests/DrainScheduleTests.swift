import Foundation
import Testing
@testable import Companion

private let drainClock = Date(timeIntervalSince1970: 1792065600)
private func drainTime(_ seconds: Int = 0) -> String {
    drainClock.addingTimeInterval(TimeInterval(seconds)).ISO8601Format()
}
private func drainID(_ byte: UInt8) -> String { CompanionWire.base64(Data(repeating: byte, count: 16)) }
private let drainDevices = (1...5).map { drainID(UInt8($0)) }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }

@Test func rotatingStartsServeEveryDeviceWhenOnlyTheFirstFitsTheDrainBudget() throws {
    var schedule = CompanionDrainSchedule()
    var serviced: [String] = []
    for _ in 0..<10 {
        let plan = try schedule.plan(activeDevices: Array(drainDevices.reversed()), now: drainTime())
        serviced.append(try #require(plan.first))
    }
    #expect(serviced == drainDevices + drainDevices)
}

@Test func aBackedOffStartingDeviceNeverDelaysTheOthersOrStopsTheRotation() throws {
    var schedule = CompanionDrainSchedule()
    _ = try schedule.plan(activeDevices: drainDevices, now: drainTime())
    try schedule.recordTurn(deviceID: drainDevices[1], decisionsCommitted: 0, retryableFailure: true, now: drainTime())
    let plan = try schedule.plan(activeDevices: drainDevices, now: drainTime(59))
    #expect(plan == Array(drainDevices[2...]) + [drainDevices[0]])
    #expect(try schedule.plan(activeDevices: drainDevices, now: drainTime(60)).first == drainDevices[2])
}

@Test func deviceRetriesDoubleToOneHourAndAnIdleTurnDoesNotResetTheChain() throws {
    var schedule = CompanionDrainSchedule()
    let device = drainDevices[0]
    var elapsed = 0
    _ = try schedule.plan(activeDevices: [device], now: drainTime())
    for minutes in [1, 2, 4, 8, 16, 32, 60, 60] {
        try schedule.recordTurn(deviceID: device, decisionsCommitted: 0, retryableFailure: true, now: drainTime(elapsed))
        #expect(try schedule.plan(activeDevices: [device], now: drainTime(elapsed + minutes * 60 - 1)).isEmpty)
        elapsed += minutes * 60
        #expect(try schedule.plan(activeDevices: [device], now: drainTime(elapsed)) == [device])
        try schedule.recordTurn(deviceID: device, decisionsCommitted: 0, retryableFailure: false, now: drainTime(elapsed))
    }
    try schedule.recordTurn(deviceID: device, decisionsCommitted: 1, retryableFailure: true, now: drainTime(elapsed))
    #expect(try schedule.plan(activeDevices: [device], now: drainTime(elapsed + 59)).isEmpty)
    #expect(try schedule.plan(activeDevices: [device], now: drainTime(elapsed + 60)) == [device])
    try schedule.recordTurn(deviceID: device, decisionsCommitted: 1, retryableFailure: false, now: drainTime(elapsed + 60))
    try schedule.recordTurn(deviceID: device, decisionsCommitted: 0, retryableFailure: true, now: drainTime(elapsed + 60))
    #expect(try schedule.plan(activeDevices: [device], now: drainTime(elapsed + 120)) == [device])
}

@Test func removingADevicePrunesItsRetryAndRotationContinuesAfterTheRemovedStart() throws {
    var schedule = CompanionDrainSchedule()
    _ = try schedule.plan(activeDevices: drainDevices, now: drainTime())
    try schedule.recordTurn(deviceID: drainDevices[0], decisionsCommitted: 0, retryableFailure: true, now: drainTime())
    #expect(try schedule.plan(activeDevices: Array(drainDevices.dropFirst()), now: drainTime()).first == drainDevices[1])
    #expect(try schedule.plan(activeDevices: drainDevices, now: drainTime()).contains(drainDevices[0]))
    _ = try schedule.plan(activeDevices: [], now: drainTime())
    #expect(try schedule.plan(activeDevices: drainDevices, now: drainTime()) == drainDevices)
}

@Test func invalidScheduleInputsCannotAdvanceTheCursorOrChangeRetryMemory() throws {
    var schedule = CompanionDrainSchedule()
    _ = try schedule.plan(activeDevices: drainDevices, now: drainTime())
    try schedule.recordTurn(deviceID: drainDevices[0], decisionsCommitted: 0, retryableFailure: true, now: drainTime())
    let invalidLists = [["../credentials"], [drainDevices[0], drainDevices[0]], (1...21).map { drainID(UInt8($0)) }]
    for list in invalidLists {
        #expect(throws: CompanionRelayError.invalid) { try schedule.plan(activeDevices: list, now: drainTime()) }
    }
    #expect(throws: CompanionRelayError.invalid) { try schedule.plan(activeDevices: [], now: "invalid") }
    #expect(throws: CompanionRelayError.invalid) { try schedule.recordTurn(deviceID: drainID(70), decisionsCommitted: 1, retryableFailure: false, now: drainTime()) }
    for count in [-1, 501] {
        #expect(throws: CompanionRelayError.invalid) { try schedule.recordTurn(deviceID: drainDevices[0], decisionsCommitted: count, retryableFailure: false, now: drainTime()) }
    }
    #expect(throws: CompanionRelayError.invalid) { try schedule.recordTurn(deviceID: drainDevices[0], decisionsCommitted: 1, retryableFailure: false, now: "invalid") }
    let plan = try schedule.plan(activeDevices: drainDevices, now: drainTime(59))
    #expect(plan == Array(drainDevices.dropFirst()))
}
