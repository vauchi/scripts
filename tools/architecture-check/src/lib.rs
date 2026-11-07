// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

mod collect;
pub mod complexity;
mod cycles;
mod includes;
mod macros;
mod metadata;
pub mod policy;
mod resolve;
mod syntax;

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct Reference {
    pub source: String,
    pub target: String,
    pub file: String,
    pub owner: String,
    pub symbol: String,
    pub via: BTreeSet<String>,
    pub line: usize,
    pub column: usize,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Report {
    pub dependencies: BTreeMap<String, BTreeSet<String>>,
    pub unscanned_targets: BTreeMap<String, BTreeSet<String>>,
    pub modules: BTreeSet<String>,
    pub references: BTreeSet<Reference>,
    pub apis: BTreeSet<String>,
    pub files: BTreeSet<String>,
}

pub fn analyze(root: &Path) -> Result<Report, String> {
    analyze_with_generated(root, None)
}

pub fn analyze_with_generated(root: &Path, generated: Option<&Path>) -> Result<Report, String> {
    collect::Index::load(root, generated)?.report()
}
