// swift-tools-version:5.9
import PackageDescription

// L'Info.plist est embarqué dans le binaire : ça autorise le HTTP (ATS) même
// quand on lance l'app avec `swift run`, sans passer par le bundle .app.
let infoPlist = Context.packageDirectory + "/Sources/CatchupDownloader/Info.plist"

let package = Package(
    name: "CatchupDownloader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CatchupDownloader",
            path: "Sources/CatchupDownloader",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ])
            ]
        )
    ]
)
