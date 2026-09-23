import Foundation
@testable import FleetRollout

enum Fixture {

    static func device(
        _ identifier: String = "device-0000",
        train: BuildTrain = .ios27_2,
        deviceClass: DeviceClass = .phoneStandard,
        posture: PostureCapability = .fixed,
        appBuild: Int = 1_201,
        attributes: [String: String] = [:]
    ) -> DeviceContext {
        DeviceContext(
            stableIdentifier: identifier,
            buildTrain: train,
            deviceClass: deviceClass,
            posture: posture,
            appBuild: appBuild,
            attributes: attributes)
    }

    static let duoDevice = device(
        "device-duo", train: .ios27_1Duo, deviceClass: .phoneDuo, posture: .foldable)

    static func flag(
        key: String = "checkout.duo_layout",
        salt: String = "s1",
        rules: [RolloutRule] = [],
        killed: Bool = false
    ) -> FlagDefinition {
        FlagDefinition(
            key: key,
            salt: salt,
            variants: [
                Variant(key: "off", value: .bool(false)),
                Variant(key: "on", value: .bool(true))
            ],
            defaultVariantKey: "off",
            rules: rules,
            killed: killed)
    }

    static func document(
        version: Int = 10,
        issuedAt: Date = Date(timeIntervalSince1970: 1_758_585_600),
        flags: [FlagDefinition]? = nil,
        maxAge: TimeInterval = 300,
        staleWhileRevalidate: TimeInterval = 86_400
    ) -> ConfigDocument {
        ConfigDocument(
            documentVersion: version,
            issuedAt: issuedAt,
            maxAge: maxAge,
            staleWhileRevalidate: staleWhileRevalidate,
            flags: flags ?? [flag()],
            integrity: .unsigned)
    }

    static let fallback = FallbackCatalog(values: [
        "checkout.duo_layout": .bool(false),
        "search.rerank": .string("baseline")
    ])
}
