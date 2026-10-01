// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Strumline",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // xtool wants exactly one library product: the app itself.
        .library(name: "Strumline", targets: ["Strumline"]),
    ],
    targets: [
        // Ogg Vorbis decoder (public domain, nothings/stb).
        .target(
            name: "CStbVorbis",
            cSettings: [.define("STB_VORBIS_NO_PUSHDATA_API")]
        ),
        // libopus 1.5.2 (BSD), decoder + encoder sources, portable C paths only.
        .target(
            name: "COpus",
            exclude: ["COPYING"],
            cSettings: [
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("src"),
                .headerSearchPath("include"),
                .define("OPUS_BUILD"),
                .define("USE_ALLOCA"),
                .define("HAVE_LRINTF"),
                .define("HAVE_LRINT"),
            ]
        ),
        .target(name: "CAtomics"),
        // Platform-independent: song formats, audio decoding, gameplay rules.
        // Builds and is tested on Linux (see Tools/).
        .target(
            name: "StrumCore",
            dependencies: ["CStbVorbis", "COpus", "CAtomics"]
        ),
        .target(
            name: "Strumline",
            dependencies: ["StrumCore"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
