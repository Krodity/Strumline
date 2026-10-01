// swift-tools-version: 6.0
// Linux test harness for StrumCore (the app package itself only builds for
// iOS). Sources are symlinked from ../../Sources.
import PackageDescription

let package = Package(
    name: "corecheck",
    targets: [
        .target(name: "CStbVorbis", cSettings: [.define("STB_VORBIS_NO_PUSHDATA_API")]),
        .target(name: "COpus", exclude: ["COPYING"], cSettings: [
            .headerSearchPath("celt"), .headerSearchPath("silk"), .headerSearchPath("silk/float"),
            .headerSearchPath("src"), .headerSearchPath("include"),
            .define("OPUS_BUILD"), .define("USE_ALLOCA"), .define("HAVE_LRINTF"), .define("HAVE_LRINT"),
        ]),
        .target(name: "CAtomics"),
        .target(name: "StrumCore", dependencies: ["CStbVorbis", "COpus", "CAtomics"]),
        .executableTarget(name: "corecheck", dependencies: ["StrumCore"]),
        // Stand-in online player for testing online play with one phone.
        .executableTarget(name: "strumnet", dependencies: ["StrumCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
