import Foundation
import SpravaKit

/// How an offload resumes after an interruption, and how one that can no longer be current is abandoned with its
/// pins released (docs/backup.md §6.1).
extension Backup {
    /// Brings a job an interruption left mid-step to a stage either entry point continues from: an abandonment cut
    /// off is finished (and reported), and a snapshot write cut off is adopted if restic committed it, its strays
    /// unpinned, or else started over. Restic may have committed the pinned snapshot just before Sprava stopped: the
    /// intent saved before the run tells that new pin from every older one.
    func recoverInterrupted(_ id: String, _ job: inout InProgress, _ st: inout State) throws {
        if job.stage == "abandoning" {
            try finishAbandoningOffload(id, job, &st)
            throw Failure(message: "the earlier offload was abandoned safely; offload again to back up the current binder")
        }
        guard job.stage == "writing" else { return }
        guard let repository = job.repository, let expected = job.manifestSHA, let pinsBefore = job.pinsBeforeWrite else {
            throw Failure(message: "the offload's snapshot intent is incomplete; nothing was removed")
        }
        let primary = try engine(repository)
        let known = Set(pinsBefore)
        let candidates = try primary.snapshots(tag: "binder:\(id)").filter { $0.tags.contains("offloaded") && !known.contains($0.id) }
        var recovered: Restic.Snapshot?
        for candidate in candidates {
            let manifest = try restoredManifest(candidate.id, from: primary, id: "writing-\(id)")
            if Self.digest(manifest) == expected, recovered == nil { recovered = candidate }
        }
        for candidate in candidates where candidate.id != recovered?.id {
            try primary.removeTag("offloaded", from: candidate.id)
        }
        if let recovered {
            job.snapshot = recovered.id
            job.bytes = recovered.bytes ?? 0
            job.stage = "snapshotted"
        } else {
            job.stage = "start"
        }
        job.pinsBeforeWrite = nil
        st.offloads[id] = job
        try save(st)
    }

    /// A crash after recording a snapshot resumes verification of that exact pinned snapshot. Replacing it on every
    /// retry would leave each abandoned `offloaded` tag outside retention for ever.
    /// A job that has a mirror snapshot goes on only while the mirror holds it; otherwise it is abandoned (its other
    /// pins released) and the binder is offloaded again from the start.
    func requireMirrorSnapshot(_ id: String, _ job: inout InProgress, _ st: inout State) throws {
        guard let snap = job.snapshot, let repository = job.repository, !["start", "writing", "abandoning"].contains(job.stage) else { return }
        guard try engine(repository).snapshots(tag: "binder:\(id)").contains(where: { $0.id == snap }) else {
            try abandonOffload(id, job, &st)
            throw Failure(message: "the mirror no longer holds the offload's snapshot; nothing was removed. Offload again")
        }
    }

    /// For a leaving binder no longer at its path: the copies its record names are still in the current backups.
    /// Nothing is changed when they are not; the job and its pins stay, and the offload cannot finish.
    func requireRecordedCopies(_ id: String, _ job: InProgress, _ s: Settings) throws {
        let kept = Failure(message: "the binder is not where its offload started, and the backups no longer hold the copies "
            + "its offload recorded; nothing was finished, and the copies left stay pinned")
        // Two copies only while the repositories are still independent (a saved second path may lead elsewhere now).
        try refuseSharedFate(s)
        guard let mirror = job.repository, mirror == s.primary, let snap = job.snapshot,
              try engine(mirror).snapshots(tag: "binder:\(id)").contains(where: { $0.id == snap }) else { throw kept }
        if let second = job.secondRepository {
            guard second == s.second, let copy = job.secondSnapshot,
                  try engine(second).snapshots(tag: "binder:\(id)").contains(where: { $0.id == copy }) else { throw kept }
        }
    }

    func verifySnapshotted(_ id: String, _ job: inout InProgress, _ st: inout State) throws {
        guard let snap = job.snapshot, let expected = job.manifestSHA else {
            throw Failure(message: "the offload's recorded snapshot is incomplete; nothing was removed")
        }
        let restored = try restoredManifest(snap, from: engine(job.repository), id: id)
        guard Self.digest(restored) == expected else {
            try abandonOffload(id, job, &st)
            throw Failure(message: "the snapshot does not match the binder as it was snapshotted; nothing was removed")
        }
        job.stage = "verified"
        st.offloads[id] = job
        try save(st)
        step("offload.verified")
    }

    /// Takes the pins off what this job may have in its second backup: its recorded copy, and any copy that landed
    /// before its id was saved (one not pinned before the copy ran).
    func releaseSecond(_ id: String, _ job: InProgress) throws {
        guard let repository = job.secondRepository else { return }
        let second = try engine(repository)
        if let copy = job.secondSnapshot { try second.removeTag("offloaded", from: copy) }
        if let before = job.secondPinsBefore {
            for snap in try second.snapshots(tag: "binder:\(id)") where snap.tags.contains("offloaded") && !before.contains(snap.id) {
                try second.removeTag("offloaded", from: snap.id)
            }
        }
    }

    /// Releases the retention pins of an offload that was proven unusable while its live binder is still present.
    /// The abandoning stage is durable before a tag change can replace a snapshot id. A retry then goes directly to
    /// idempotent cleanup instead of trying to restore the obsolete id as a still-snapshotted job.
    func abandonOffload(_ id: String, _ job: InProgress, _ st: inout State) throws {
        var marked = job
        marked.stage = "abandoning"
        st.offloads[id] = marked
        try save(st)
        step("offload.abandoning")
        try finishAbandoningOffload(id, marked, &st)
    }

    func finishAbandoningOffload(_ id: String, _ job: InProgress, _ st: inout State) throws {
        // The live binder is still here, so these no-longer-current snapshots need no retention pin. Remove the pins
        // before forgetting the job; if a repository is away, the job remains and the cleanup is retried. removeTag is
        // idempotent if a crash lands between repositories or before the state save. A job a state snapshot holds as
        // leaving keeps its pins: that snapshot, restored after this Mac is lost, would finish the offload from them.
        if let repository = job.repository, !job.checkpointed {
            let primary = try engine(repository)
            if let snapshot = job.snapshot { try primary.removeTag("offloaded", from: snapshot) }
            // A write cut off before its snapshot id was saved leaves a pin only the intent can tell apart.
            if let before = job.pinsBeforeWrite {
                for snap in try primary.snapshots(tag: "binder:\(id)") where snap.tags.contains("offloaded") && !before.contains(snap.id) {
                    try primary.removeTag("offloaded", from: snap.id)
                }
            }
        }
        if !job.checkpointed { try releaseSecond(id, job) }
        st.offloads[id] = nil
        // Only the record this offload made (once it had one), never an earlier offload's.
        st.offloaded.removeAll { $0.backupID == id && job.snapshot != nil && $0.snapshot == job.snapshot }
        try save(st)
    }
}
