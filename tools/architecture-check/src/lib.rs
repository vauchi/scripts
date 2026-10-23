// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::Path;

mod collect;
mod resolve;
mod syntax;

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct Reference {
    pub source: String,
    pub target: String,
    pub file: String,
    pub owner: String,
    pub symbol: String,
    pub line: usize,
    pub column: usize,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Report {
    pub modules: BTreeSet<String>,
    pub references: BTreeSet<Reference>,
    pub apis: BTreeSet<String>,
    pub files: BTreeSet<String>,
}

pub fn analyze(root: &Path) -> Result<Report, String> {
    let index = collect::Index::load(root)?;
    index.report()
}
