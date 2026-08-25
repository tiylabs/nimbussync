use crate::CoreError;
use cloudreve_protocol::RemoteItem;
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReconcilePhase {
    Prepared,
    ScanningNormal,
    ScanningTrash,
    Stabilizing,
    CommittingDeletions,
    Completed,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReconcileRun {
    pub run_id: String,
    pub phase: ReconcilePhase,
    pub generation: u64,
    pub capability_revision: u64,
    pub root_id: String,
    pub root_uri: String,
    pub cursor: Option<String>,
    pub normal_complete: bool,
    pub trash_complete: bool,
}

impl ReconcileRun {
    pub fn start(
        run_id: impl Into<String>,
        generation: u64,
        capability_revision: u64,
        root_id: impl Into<String>,
        root_uri: impl Into<String>,
    ) -> Self {
        Self {
            run_id: run_id.into(),
            phase: ReconcilePhase::Prepared,
            generation,
            capability_revision,
            root_id: root_id.into(),
            root_uri: root_uri.into(),
            cursor: None,
            normal_complete: false,
            trash_complete: false,
        }
    }

    pub fn begin_normal(&mut self) {
        self.phase = ReconcilePhase::ScanningNormal;
    }
    pub fn begin_trash(&mut self) {
        self.phase = ReconcilePhase::ScanningTrash;
    }
    pub fn mark_normal_complete(&mut self) {
        self.normal_complete = true;
    }
    pub fn mark_trash_complete(&mut self) {
        self.trash_complete = true;
    }
    pub fn stabilize(&mut self) -> Result<(), CoreError> {
        if !self.normal_complete || !self.trash_complete {
            return Err(CoreError::UnknownOutcome);
        }
        self.phase = ReconcilePhase::Stabilizing;
        Ok(())
    }
    pub fn commit_deletions(
        &mut self,
        current_capability_revision: u64,
        current_root_id: &str,
    ) -> Result<(), CoreError> {
        if self.phase != ReconcilePhase::Stabilizing
            || current_capability_revision != self.capability_revision
            || current_root_id != self.root_id
        {
            self.phase = ReconcilePhase::Failed;
            return Err(CoreError::RootUnavailable);
        }
        self.phase = ReconcilePhase::CommittingDeletions;
        Ok(())
    }
    pub fn complete(&mut self) {
        self.phase = ReconcilePhase::Completed;
    }
}

pub fn tombstone_candidates(
    expected: &HashSet<String>,
    normal: &HashSet<String>,
    trash: &HashSet<String>,
    pending: &HashSet<String>,
    normal_complete: bool,
    trash_complete: bool,
) -> Vec<String> {
    if !normal_complete || !trash_complete {
        return Vec::new();
    }
    expected
        .iter()
        .filter(|id| !normal.contains(*id) && !trash.contains(*id) && !pending.contains(*id))
        .cloned()
        .collect()
}

pub fn root_identity_after_check(
    expected_id: &str,
    observed: Option<&RemoteItem>,
) -> Result<String, CoreError> {
    let observed = observed.ok_or(CoreError::RootUnavailable)?;
    if observed.id != expected_id || !observed.can_read {
        return Err(CoreError::RootUnavailable);
    }
    Ok(observed.uri.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use cloudreve_protocol::{RemoteItem, RemoteItemKind};

    #[test]
    fn incomplete_generation_never_commits_deletions() {
        let mut run = ReconcileRun::start("run", 1, 2, "root", "/");
        run.begin_normal();
        run.mark_normal_complete();
        assert_eq!(run.stabilize(), Err(CoreError::UnknownOutcome));
        run.begin_trash();
        run.mark_trash_complete();
        run.stabilize().unwrap();
        assert_eq!(
            run.commit_deletions(3, "root"),
            Err(CoreError::RootUnavailable)
        );
    }

    #[test]
    fn root_replacement_is_not_accepted() {
        let item = RemoteItem {
            id: "new".into(),
            parent_id: None,
            uri: "/".into(),
            name: "root".into(),
            kind: RemoteItemKind::Folder,
            size: 0,
            content_etag: None,
            metadata_revision: None,
            content_type: "public.folder".into(),
            can_read: true,
            can_write: true,
            can_add_children: true,
            can_trash: false,
            can_delete: false,
            trashed: false,
        };
        assert_eq!(
            root_identity_after_check("old", Some(&item)),
            Err(CoreError::RootUnavailable)
        );
    }
}
