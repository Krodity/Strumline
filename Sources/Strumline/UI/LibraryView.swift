import SwiftUI
import UniformTypeIdentifiers
import StrumCore

struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    @State private var importing = false
    @State private var importTypes: [UTType] = [.folder]
    /// Unlinking takes two presses: the first arms the row.
    @State private var armed: UUID?

    private var rows: [NavRow] {
        var r: [NavRow] = [
            NavRow(id: "linkf", section: "Link from Files", title: "Link a Folder…", detail: "Read in place from iCloud Drive, On My iPhone, USB drives or network shares — nothing is copied.", kind: .button(destructive: false) { importTypes = [.folder]; importing = true }),
            NavRow(id: "links", section: "Link from Files", title: "Link .sng Files…", kind: .button(destructive: false) { importTypes = [UTType(filenameExtension: "sng") ?? .data]; importing = true }),
        ]
        if app.locations.isEmpty {
            r.append(NavRow(id: "none", section: "Linked", title: "Nothing linked yet", kind: .info))
        }
        for loc in app.locations {
            let isArmed = armed == loc.id
            r.append(NavRow(id: "loc-\(loc.id)", section: "Linked", title: loc.name,
                            detail: isArmed ? "Press again to unlink — its songs leave the library (files aren't touched)" : "Press twice to unlink",
                            symbol: loc.isFile ? "shippingbox.fill" : "folder.fill",
                            kind: .button(destructive: isArmed) {
                if isArmed { armed = nil; app.unlink(loc) } else { armed = loc.id }
            }))
        }
        r += [
            NavRow(id: "appdir", section: "App folder", title: "On My iPhone › Strumline › Songs", detail: "Copy songs here with the Files app, Finder or AirDrop to keep them on the device.", kind: .info),
            NavRow(id: "count", section: "Library", title: app.scanning ? app.scanStatus : "\(app.songs.count) songs", detail: app.pendingDownloads > 0 ? "Waiting on \(app.pendingDownloads) iCloud download(s)" : "Scanned once and kept on this iPhone; only rescanned when you ask.", kind: .info),
            NavRow(id: "rescan", section: "Library", title: "Rescan (new & changed songs)", kind: .button(destructive: false) { app.rescan() }),
            NavRow(id: "rebuild", section: "Library", title: "Rebuild library (re-read everything)", kind: .button(destructive: false) { app.rebuildLibrary() }),
        ]
        for (i, e) in app.scanErrors.prefix(50).enumerated() {
            r.append(NavRow(id: "err\(i)", section: "Problems (\(app.scanErrors.count))", title: e, kind: .info))
        }
        return r
    }

    var body: some View {
        NavForm(rows: rows, onBack: { app.screen = .menu })
        .screenChrome("Library") { app.screen = .menu }
        // One importer only: SwiftUI ignores all but the last on a view.
        .fileImporter(isPresented: $importing, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { app.link(urls: urls) }
        }

    }
}
