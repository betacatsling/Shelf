// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shelf",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Shelf", targets: ["Shelf"])
    ],
    targets: [
        .executableTarget(
            name: "Shelf",
            path: "Sources/Shelf"
        )
    ]
)
