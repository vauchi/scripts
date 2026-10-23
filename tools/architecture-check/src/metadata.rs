// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use crate::collect::CRATES;
use serde::Deserialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
};

#[derive(Deserialize)]
struct Metadata {
    packages: Vec<Package>,
    workspace_members: Vec<String>,
}
#[derive(Deserialize)]
struct Package {
    id: String,
    name: String,
    manifest_path: PathBuf,
    targets: Vec<Target>,
    dependencies: Vec<Dependency>,
}
#[derive(Deserialize)]
struct Target {
    name: String,
    kind: Vec<String>,
    src_path: PathBuf,
}
#[derive(Deserialize)]
struct Dependency {
    name: String,
    rename: Option<String>,
    kind: Option<String>,
}

pub(crate) fn validate(
    root: &Path,
    generated: Option<&Path>,
) -> Result<BTreeMap<String, String>, String> {
    let expected: BTreeSet<_> = CRATES
        .iter()
        .filter(|name| root.join(name).join("Cargo.toml").exists())
        .copied()
        .collect();
    if expected.is_empty() && !root.join("Cargo.toml").exists() {
        return Ok(BTreeMap::new());
    }
    let path = generated
        .ok_or("fresh Cargo metadata required for manifested source")?
        .join("cargo-metadata.json");
    let metadata: Metadata =
        serde_json::from_slice(&std::fs::read(path).map_err(|e| format!("Cargo metadata: {e}"))?)
            .map_err(|e| format!("Cargo metadata: {e}"))?;
    let mut found = BTreeSet::new();
    let mut aliases = BTreeMap::new();
    for package in metadata
        .packages
        .iter()
        .filter(|p| metadata.workspace_members.contains(&p.id))
    {
        if !CRATES.contains(&package.name.as_str()) {
            return Err(format!("unsupported workspace crate: {}", package.name));
        }
        let directory = root.join(&package.name);
        if canonical(&package.manifest_path)? != canonical(&directory.join("Cargo.toml"))? {
            return Err(format!("unexpected manifest path: {}", package.name));
        }
        let libraries: Vec<_> = package
            .targets
            .iter()
            .filter(|t| {
                t.kind.iter().any(|k| {
                    matches!(
                        k.as_str(),
                        "lib" | "rlib" | "dylib" | "cdylib" | "staticlib" | "proc-macro"
                    )
                })
            })
            .collect();
        if libraries.len() != 1
            || libraries[0].name != package.name.replace('-', "_")
            || canonical(&libraries[0].src_path)? != canonical(&directory.join("src/lib.rs"))?
        {
            return Err(format!("unsupported Cargo library root: {}", package.name));
        }
        found.insert(package.name.as_str());
        for dependency in &package.dependencies {
            if dependency.kind.as_deref() == Some("dev")
                || !CRATES.contains(&dependency.name.as_str())
            {
                continue;
            }
            let target = dependency.name.replace('-', "_");
            let alias = dependency
                .rename
                .as_deref()
                .unwrap_or(&dependency.name)
                .replace('-', "_");
            if alias != target {
                aliases.insert(
                    format!("{}::{alias}", package.name.replace('-', "_")),
                    target,
                );
            }
        }
    }
    if found != expected {
        return Err("Cargo metadata does not cover all supported crates".into());
    }
    Ok(aliases)
}

fn canonical(path: &Path) -> Result<PathBuf, String> {
    path.canonicalize()
        .map_err(|e| format!("Cargo metadata path {}: {e}", path.display()))
}
