//
// Per-tab web storage.
//
// Why one data store per tab rather than one shared persistent store: the DSH
// web UI keeps the active session in localStorage under `dsh.sessions.current`
// and restores it on load (dsh-client-runtime), and it has no URL routing. With
// a single shared store every tab would write that one key and they would all
// converge on the same session -- which is exactly the thing several tabs exist
// for. A store per tab keeps the sessions independent and, as a bonus, lets each
// tab come back to its own session after a relaunch.
//
// Identified data stores need macOS 14, which is also this app's floor (see
// LSMinimumSystemVersion).
//

import Foundation
import WebKit

/// What has to survive a relaunch for a tab to come back as itself.
struct TabRecord: Codable {
    let storeID: UUID
    var name: String
    /// A name the user typed. Auto titles from the page must not overwrite it.
    var manuallyNamed: Bool
}

/// Creation, removal and housekeeping of the identified data stores.
enum TabDataStore {
    static func store(for id: UUID) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: id)
    }

    /// Drop a closed tab's storage. Without this the directories accumulate for
    /// the lifetime of the install, one per tab ever opened.
    static func remove(_ id: UUID, log: ((String) -> Void)? = nil) {
        WKWebsiteDataStore.remove(forIdentifier: id) { error in
            if let error {
                log?("cannot remove data store \(id): \(error.localizedDescription)")
            } else {
                log?("removed data store \(id)")
            }
        }
    }

    /// Remove stores that no tab claims any more -- what a crash or a forced
    /// quit leaves behind, since those skip the per-tab removal above.
    static func prune(keeping wanted: Set<UUID>, log: ((String) -> Void)? = nil) {
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
            let orphans = identifiers.filter { !wanted.contains($0) }
            guard !orphans.isEmpty else { return }
            log?("pruning \(orphans.count) orphaned data store(s)")
            for id in orphans {
                remove(id, log: log)
            }
        }
    }
}
