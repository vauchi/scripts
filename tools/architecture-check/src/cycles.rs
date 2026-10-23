// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use crate::Report;
use std::collections::{BTreeMap, BTreeSet};

type Graph<'a> = BTreeMap<&'a str, BTreeSet<&'a str>>;

pub(crate) fn components<'a>(report: &'a Report, crate_name: &str) -> Vec<BTreeSet<&'a str>> {
    let mut forward = Graph::new();
    let mut reverse = Graph::new();
    let prefix = format!("{crate_name}/");
    for r in &report.references {
        if r.source.starts_with(&prefix) && r.target.starts_with(&prefix) {
            forward.entry(&r.source).or_default().insert(&r.target);
            reverse.entry(&r.target).or_default().insert(&r.source);
        }
    }
    let mut visited = BTreeSet::new();
    let mut result = Vec::new();
    for &node in forward.keys() {
        if visited.contains(node) {
            continue;
        }
        // Mutual reachability identifies the component without including outgoing tails.
        let reachable = reachable_nodes(&forward, node);
        let predecessors = reachable_nodes(&reverse, node);
        let component: BTreeSet<_> = reachable.intersection(&predecessors).copied().collect();
        visited.extend(component.iter().copied());
        if component.len() > 1 {
            result.push(component);
        }
    }
    result
}

fn reachable_nodes<'a>(graph: &Graph<'a>, start: &'a str) -> BTreeSet<&'a str> {
    let mut seen = BTreeSet::new();
    let mut pending = vec![start];
    while let Some(node) = pending.pop() {
        if seen.insert(node) {
            if let Some(next) = graph.get(node) {
                pending.extend(next.iter().copied());
            }
        }
    }
    seen
}
