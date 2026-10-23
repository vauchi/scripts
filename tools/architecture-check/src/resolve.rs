// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use crate::{
    collect::{Index, CRATES},
    Reference, Report,
};
use std::collections::BTreeSet;

pub(crate) fn top(scope: &str) -> String {
    let mut parts = scope.split("::");
    format!(
        "{}/{}",
        parts.next().unwrap_or_default().replace('_', "-"),
        parts.next().unwrap_or("lib")
    )
}

impl Index {
    pub fn report(mut self) -> Result<Report, String> {
        for raw in &self.references {
            if std::env::var_os("VAUCHI_ARCHITECTURE_TRACE").is_some() {
                eprintln!("{}:{} {}", raw.file, raw.line, raw.path.join("::"));
            }
            let mut via = BTreeSet::new();
            let resolved = self.resolve(&raw.scope, &raw.path, &mut BTreeSet::new(), &mut via);
            let explicit = raw.path.first().is_some_and(|p| {
                matches!(p.as_str(), "crate" | "self" | "super")
                    || CRATES.iter().any(|c| c.replace('-', "_") == *p)
            });
            if resolved.is_empty() && explicit {
                return Err(format!(
                    "{}:{}: unresolved internal path {} in {}",
                    raw.file,
                    raw.line,
                    raw.path.join("::"),
                    raw.scope
                ));
            }
            for symbol in resolved {
                let source = top(&raw.scope);
                let target = self
                    .owner_module(&symbol)
                    .map(|m| top(&m))
                    .unwrap_or_else(|| top(&symbol));
                if source == target {
                    continue;
                }
                self.report.references.insert(Reference {
                    source,
                    target,
                    file: raw.file.clone(),
                    owner: raw.owner.clone(),
                    symbol,
                    via: via.clone(),
                    line: raw.line,
                    column: raw.column,
                });
            }
        }
        Ok(self.report)
    }

    fn owner_module(&self, symbol: &str) -> Option<String> {
        let mut prefix = symbol.to_string();
        loop {
            if self.modules.contains(&prefix) {
                return Some(prefix);
            }
            prefix = prefix.rsplit_once("::")?.0.to_string();
        }
    }

    fn resolve(
        &self,
        scope: &str,
        path: &[String],
        visiting: &mut BTreeSet<String>,
        via: &mut BTreeSet<String>,
    ) -> BTreeSet<String> {
        if path.is_empty() {
            return BTreeSet::new();
        }
        let mut base: Vec<String> = scope.split("::").map(String::from).collect();
        let mut offset = 0;
        match path[0].as_str() {
            "crate" => {
                base.truncate(1);
                offset = 1;
            }
            "self" => offset = 1,
            "super" => {
                while offset < path.len() && path[offset] == "super" {
                    if base.len() > 1 {
                        base.pop();
                    }
                    offset += 1;
                }
            }
            first if CRATES.iter().any(|c| c.replace('-', "_") == first) => {
                base.clear();
            }
            _ => {}
        }
        base.extend_from_slice(&path[offset..]);
        let absolute = base.join("::");
        for end in 1..=base.len() {
            let prefix = base[..end].join("::");
            if self.modules.contains(&prefix) {
                via.insert(top(&prefix));
            }
        }
        if !visiting.insert(absolute.clone()) {
            return BTreeSet::new();
        }
        let mut result = BTreeSet::new();
        for end in (1..=base.len()).rev() {
            let prefix = base[..end].join("::");
            if let Some(imports) = self.imports.get(&prefix) {
                for import in imports {
                    let mut target = import.path.clone();
                    target.extend_from_slice(&base[end..]);
                    result.extend(self.resolve(&import.scope, &target, visiting, via));
                }
                if !result.is_empty() {
                    break;
                }
            }
            if self.symbols.contains(&prefix) && !self.modules.contains(&prefix) {
                result.insert(absolute.clone());
                break;
            }
            if self.modules.contains(&prefix) {
                if end == base.len() {
                    result.insert(prefix);
                    break;
                }
                if let Some(globs) = self.globs.get(&prefix) {
                    for glob in globs {
                        let guard = format!("glob:{prefix}:{}", glob.path.join("::"));
                        if !visiting.insert(guard.clone()) {
                            continue;
                        }
                        let mut target = glob.path.clone();
                        target.extend_from_slice(&base[end..]);
                        result.extend(self.resolve(&glob.scope, &target, visiting, via));
                        visiting.remove(&guard);
                    }
                }
                break;
            }
        }
        visiting.remove(&absolute);
        result
    }
}
