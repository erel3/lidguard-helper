// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "lidguard-helper",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/Lakr233/SkyLightWindow", from: "1.0.0")
  ],
  targets: [
    .executableTarget(
      name: "lidguard-helper",
      dependencies: ["SkyLightWindow"],
      path: "Sources",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "lidguard-helperTests",
      dependencies: ["lidguard-helper"],
      path: "Tests/lidguard-helperTests",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    )
  ]
)
