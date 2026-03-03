// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WE",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "WE", targets: ["WE"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.5.0")
    ],
    targets: [
        .systemLibrary(
            name: "CllmBase",
            path: "Sources/CllmBase",
            pkgConfig: "llama",
            providers: []
        ),
        .executableTarget(
            name: "WE",
            dependencies: [
                "CllmBase",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            exclude: ["CllmBase"],
            swiftSettings: [
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64")
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalPerformanceShaders"),
                .unsafeFlags([
                    "-Llibs/llama.cpp/build/src",
                    "-Llibs/llama.cpp/build/ggml/src",
                    "-lllama",
                    "-lggml",
                    "-lggml-base",
                    "-lggml-metal",
                    "-lggml-cpu",
                    "-lggml-blas",
                ])
            ]
        ),
        .testTarget(
            name: "WETests",
            dependencies: ["WE"],
            path: "Tests"
        )
    ]
)
