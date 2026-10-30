// swift-tools-version:6.0
// id-011 follow-up: how many threads does the Swift concurrency executor give
// tasks that block their thread, and does SwiftPM 6.4.0's FIFO test pattern
// (FileSystemTests.swift:30-47) need more than one? Swift Testing only.
import PackageDescription

let package = Package(
    name: "pool-probe",
    targets: [.testTarget(name: "PoolProbeTests")]
)
