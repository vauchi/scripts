// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use crate::Report;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub schema_version: u32,
    pub crates: BTreeMap<String, u32>,
    pub layers: BTreeMap<String, u32>,
    pub compatibility_modules: BTreeSet<String>,
    #[serde(default)]
    pub acyclic_crates: BTreeSet<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Allowance {
    pub count: usize,
    pub issue: String,
    pub reason: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Baseline {
    pub schema_version: u32,
    pub exceptions: BTreeMap<String, Allowance>,
    pub apis: BTreeSet<String>,
}

pub fn violations(report: &Report, policy: &Policy) -> Result<BTreeMap<String, usize>, String> {
    if policy.schema_version != 1 {
        return Err("unsupported policy version".into());
    }
    for name in &policy.acyclic_crates {
        if !policy.crates.contains_key(name) {
            return Err(format!("unknown acyclic crate {name}"));
        }
    }
    for name in policy.crates.keys() {
        if !report.modules.contains(&format!("{name}/lib")) {
            return Err(format!("missing configured crate {name}"));
        }
    }
    for module in report.modules.iter().chain(
        report
            .references
            .iter()
            .flat_map(|r| [&r.source, &r.target]),
    ) {
        let (name, _) = module.split_once('/').ok_or("invalid module identity")?;
        if !policy.crates.contains_key(name) || !policy.layers.contains_key(module) {
            return Err(format!("unclassified module {module}"));
        }
    }
    let mut result = BTreeMap::new();
    for r in &report.references {
        let source_crate = r.source.split('/').next().unwrap();
        let target_crate = r.target.split('/').next().unwrap();
        let upward = if source_crate == target_crate {
            policy.layers[&r.source] < policy.layers[&r.target]
        } else {
            policy.crates[source_crate] < policy.crates[target_crate]
        };
        let compatibility = (policy.compatibility_modules.contains(&r.target)
            || !policy.compatibility_modules.is_disjoint(&r.via))
            && source_crate == target_crate
            && !r.source.ends_with("/lib")
            && !policy.compatibility_modules.contains(&r.source);
        if upward || compatibility {
            // Source locations aid diagnostics but line shifts must not grant new exceptions.
            let key = serde_json::to_string(&[&r.source, &r.target, &r.file, &r.owner, &r.symbol])
                .map_err(|e| e.to_string())?;
            *result.entry(key).or_default() += 1;
        }
    }
    Ok(result)
}

pub fn check(report: &Report, policy: &Policy, baseline: &Baseline) -> Result<(), Vec<String>> {
    validate_baseline(baseline).map_err(|e| vec![e])?;
    let measured = violations(report, policy).map_err(|e| vec![e])?;
    let mut errors = Vec::new();
    for name in &policy.acyclic_crates {
        for component in crate::cycles::components(report, name) {
            errors.push(format!(
                "VRS06: ownership cycle: {}; relocate composition to its consuming module",
                component.into_iter().collect::<Vec<_>>().join(", ")
            ));
        }
    }
    for (key, count) in &measured {
        let allowed = baseline.exceptions.get(key).map_or(0, |a| a.count);
        if *count > allowed {
            errors.push(format!("VRS06: {key}: {count} sites, {allowed} allowed; move the dependency to its owning lower layer"));
        }
    }
    for (key, allowance) in &baseline.exceptions {
        let count = measured.get(key).copied().unwrap_or(0);
        if count < allowance.count {
            errors.push(format!(
                "VRS06: {key}: tighten baseline from {} to {count} sites in this change",
                allowance.count
            ));
        }
    }
    for api in report.apis.difference(&baseline.apis) {
        errors.push(format!(
            "VRS06: new legacy API {api}; use the Command/Event channel"
        ));
    }
    for api in baseline.apis.difference(&report.apis) {
        errors.push(format!("VRS06: remove retired API {api} from the baseline"));
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

fn validate_baseline(baseline: &Baseline) -> Result<(), String> {
    if baseline.schema_version != 1 {
        return Err("unsupported baseline version".into());
    }
    if baseline
        .exceptions
        .values()
        .any(|a| a.count == 0 || a.issue.trim().is_empty() || a.reason.trim().is_empty())
    {
        return Err("each exception requires a positive count, issue and reason".into());
    }
    Ok(())
}

pub fn validate_tightening(before: &Baseline, after: &Baseline) -> Result<(), String> {
    validate_baseline(before)?;
    validate_baseline(after)?;
    for (key, allowance) in &after.exceptions {
        if before
            .exceptions
            .get(key)
            .is_none_or(|old| allowance.count > old.count)
        {
            return Err(format!("VRS06: baseline widened for {key}"));
        }
    }
    if !after.apis.is_subset(&before.apis) {
        return Err("VRS06: legacy API baseline widened".into());
    }
    Ok(())
}

pub fn validate_policy_tightening(before: &Policy, after: &Policy) -> Result<(), String> {
    if before.schema_version != 1 || after.schema_version != 1 {
        return Err("unsupported policy version".into());
    }
    if !before.acyclic_crates.is_subset(&after.acyclic_crates) {
        return Err("VRS06: acyclic ownership policy weakened".into());
    }
    for (name, level) in &before.crates {
        if after.crates.get(name) != Some(level) {
            return Err(format!("VRS06: crate policy changed for {name}"));
        }
    }
    for (name, level) in &before.layers {
        if after.layers.get(name) != Some(level) {
            return Err(format!(
                "VRS06: layer policy changed for {name}; retain the approved ownership model"
            ));
        }
    }
    if !before
        .compatibility_modules
        .is_subset(&after.compatibility_modules)
    {
        return Err("VRS06: compatibility policy weakened".into());
    }
    Ok(())
}
