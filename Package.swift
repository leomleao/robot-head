// swift-tools-version: 6.4
//
// RobotKit: native characters for macOS, drawn with Metal. CharacterKit is the
// contract every character conforms to, with the view, pacing and lip-sync they
// share; IronGiant is the first character. The TypeScript library next to it is
// unaffected: SwiftPM only looks at Sources/ and Tests/.

import PackageDescription

let package = Package(
    name: "RobotKit",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "CharacterKit", targets: ["CharacterKit"]),
        .library(name: "IronGiant", targets: ["IronGiant"]),
        .executable(name: "RobotPlayground", targets: ["RobotPlayground"]),
    ],
    targets: [
        .target(name: "CharacterKit"),
        .target(name: "IronGiant", dependencies: ["CharacterKit"]),
        .executableTarget(name: "RobotPlayground", dependencies: ["CharacterKit", "IronGiant"]),
        .testTarget(name: "CharacterKitTests", dependencies: ["CharacterKit"]),
        .testTarget(name: "IronGiantTests", dependencies: ["IronGiant", "CharacterKit"], exclude: ["Fixtures", "Snapshots"]),
    ],
    swiftLanguageModes: [.v6]
)
