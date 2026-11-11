// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use crate::{syntax, Report};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use syn::{visit::Visit, Item};

pub(crate) const CRATES: &[&str] = &[
    "vauchi-protocol",
    "vauchi-core",
    "vauchi-app",
    "vauchi-platform",
    "vauchi-cabi",
    "vauchi-hardware",
    // Dev-only shared test helpers, a dependency of other crates' tests
    // and never of their libraries (vauchi/private#1230).
    "vauchi-core-testkit",
];

#[derive(Clone, Debug)]
pub(crate) struct Import {
    pub scope: String,
    pub path: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct RawReference {
    pub scope: String,
    pub file: String,
    pub owner: String,
    pub path: Vec<String>,
    pub line: usize,
    pub column: usize,
}

#[derive(Default)]
pub(crate) struct Index {
    pub symbols: BTreeSet<String>,
    pub modules: BTreeSet<String>,
    pub imports: BTreeMap<String, Vec<Import>>,
    pub globs: BTreeMap<String, Vec<Import>>,
    pub references: Vec<RawReference>,
    pub report: Report,
    pub crate_aliases: BTreeMap<String, String>,
    macro_definitions: BTreeMap<String, syn::ItemMacro>,
    active_macros: BTreeSet<String>,
    active_files: BTreeSet<PathBuf>,
    file_modules: BTreeSet<String>,
    generated: Option<PathBuf>,
}

impl Index {
    pub fn load(root: &Path, generated: Option<&Path>) -> Result<Self, String> {
        let root = root
            .canonicalize()
            .map_err(|e| format!("source root: {e}"))?;
        let mut report = Report::default();
        let mut index = Self {
            crate_aliases: crate::metadata::validate(&root, generated, &mut report)?,
            report,
            generated: generated
                .map(Path::canonicalize)
                .transpose()
                .map_err(|e| e.to_string())?,
            ..Self::default()
        };
        for name in CRATES {
            let source = root.join(name).join("src");
            if source.is_dir() {
                index.file(
                    &root,
                    &source,
                    &source.join("lib.rs"),
                    &name.replace('-', "_"),
                )?;
            }
        }
        if index.report.files.is_empty() {
            return Err("no supported crate roots found".into());
        }
        Ok(index)
    }

    fn file(&mut self, root: &Path, source: &Path, file: &Path, scope: &str) -> Result<(), String> {
        let canonical = file
            .canonicalize()
            .map_err(|e| format!("{}: {e}", file.display()))?;
        let source = source.canonicalize().map_err(|e| e.to_string())?;
        if !canonical.starts_with(&source) {
            return Err(format!("module escapes source tree: {}", file.display()));
        }
        if !self.active_files.insert(canonical.clone()) {
            return Err(format!("recursive module file: {}", file.display()));
        }
        let text = std::fs::read_to_string(&canonical).map_err(|e| e.to_string())?;
        let ast = syn::parse_file(&text).map_err(|e| format!("{}: {e}", file.display()))?;
        let relative = if let Ok(relative) = canonical.strip_prefix(root) {
            relative.to_string_lossy().replace('\\', "/")
        } else if let Some(generated) = &self.generated {
            format!(
                "@generated/{}",
                canonical
                    .strip_prefix(generated)
                    .map_err(|e| e.to_string())?
                    .to_string_lossy()
            )
        } else {
            return Err("source outside configured roots".into());
        };
        self.report.files.insert(relative.clone());
        self.file_modules.insert(scope.into());
        let parent = canonical.parent().ok_or("module has no parent")?;
        let stem = canonical
            .file_stem()
            .and_then(|s| s.to_str())
            .ok_or("invalid module filename")?;
        let module_dir = if matches!(stem, "lib" | "mod") {
            parent.to_path_buf()
        } else {
            parent.join(stem)
        };
        self.items(
            root,
            &source,
            &canonical,
            &module_dir,
            scope,
            &relative,
            &ast.items,
        )?;
        self.active_files.remove(&canonical);
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn items(
        &mut self,
        root: &Path,
        source: &Path,
        file: &Path,
        module_dir: &Path,
        scope: &str,
        relative: &str,
        items: &[Item],
    ) -> Result<(), String> {
        self.modules.insert(scope.into());
        self.report.modules.insert(crate::resolve::top(scope));
        for item in items {
            if let Item::Macro(m) = item {
                if m.mac.path.is_ident("macro_rules") && !syntax::test_only(&m.attrs) {
                    if let Some(name) = &m.ident {
                        self.macro_definitions
                            .insert(format!("{scope}::{name}"), m.clone());
                    }
                }
            }
        }
        for item in items {
            if syntax::test_only(syntax::attributes(item)) {
                continue;
            }
            if let Some(name) = syntax::item_name(item) {
                self.symbols.insert(format!("{scope}::{name}"));
            }
            if let Item::Macro(mac) = item {
                if mac.mac.path.is_ident("include") {
                    let (include_root, child) = crate::includes::resolve(
                        &mac.mac,
                        source,
                        file,
                        self.generated.as_deref(),
                    )?;
                    self.file(root, &include_root, &child, scope)?;
                    continue;
                }
                let name = mac.mac.path.segments.last().unwrap().ident.to_string();
                let mut ancestor = Some(scope);
                while let Some(parent) = ancestor {
                    let key = format!("{parent}::{name}");
                    if let Some(definition) = self.macro_definitions.get(&key).cloned() {
                        if !self.active_macros.insert(key.clone()) {
                            return Err(format!("recursive local macro: {key}"));
                        }
                        let expanded = crate::macros::expand(&mac.mac, &[Item::Macro(definition)])?
                            .ok_or_else(|| format!("unsupported local macro: {key}"))?;
                        self.items(root, source, file, module_dir, scope, relative, &expanded)?;
                        self.active_macros.remove(&key);
                        break;
                    }
                    ancestor = parent.rsplit_once("::").map(|(p, _)| p);
                }
                if ancestor.is_some() {
                    continue;
                }
            }
            if let Item::Mod(module) = item {
                let child_scope = format!("{scope}::{}", module.ident);
                if let Some((_, nested)) = &module.content {
                    self.items(
                        root,
                        source,
                        file,
                        &module_dir.join(module.ident.to_string()),
                        &child_scope,
                        relative,
                        nested,
                    )?;
                } else {
                    let explicit = syntax::module_path(&module.attrs)?;
                    let child = if let Some(path) = explicit {
                        let parent = if self.file_modules.contains(scope) {
                            file.parent().ok_or("module parent missing")?
                        } else {
                            module_dir
                        };
                        parent.join(path)
                    } else {
                        let flat = module_dir.join(format!("{}.rs", module.ident));
                        let nested = module_dir.join(module.ident.to_string()).join("mod.rs");
                        if flat.is_file() && nested.is_file() {
                            return Err(format!("ambiguous module: {child_scope}"));
                        }
                        if flat.is_file() {
                            flat
                        } else {
                            nested
                        }
                    };
                    self.file(root, source, &child, &child_scope)?;
                }
                continue;
            }
            let owner = syntax::item_name(item).unwrap_or_else(|| "module".into());
            let mut visitor = syntax::Collector {
                index: self,
                scope: scope.into(),
                file: relative.into(),
                owner: format!("{scope}::{owner}"),
                error: None,
            };
            visitor.visit_item(item);
            if let Some(error) = visitor.error {
                return Err(error);
            }
            self.exported_api(scope, item);
        }
        Ok(())
    }

    fn exported_api(&mut self, scope: &str, item: &Item) {
        match item {
            Item::Enum(e) if e.ident == "DomainCommand" || e.ident == "DomainCommandResult" => {
                for variant in &e.variants {
                    self.report
                        .apis
                        .insert(format!("{scope}::{}::{}", e.ident, variant.ident));
                }
            }
            Item::Fn(f)
                if f.sig
                    .abi
                    .as_ref()
                    .and_then(|a| a.name.as_ref())
                    .is_some_and(|n| matches!(n.value().as_str(), "C" | "C-unwind")) =>
            {
                self.report
                    .apis
                    .insert(format!("{scope}::cabi::{}", f.sig.ident));
            }
            Item::Impl(i) if syntax::uniffi_export(&i.attrs) => {
                use quote::ToTokens;
                for member in &i.items {
                    if let syn::ImplItem::Fn(f) = member {
                        if matches!(f.vis, syn::Visibility::Public(_))
                            && !syntax::test_only(&f.attrs)
                        {
                            self.report.apis.insert(format!(
                                "{scope}::uniffi::{}::{}",
                                i.self_ty.to_token_stream(),
                                f.sig.ident
                            ));
                        }
                    }
                }
            }
            Item::Trait(t) if syntax::uniffi_export(&t.attrs) => {
                self.report
                    .apis
                    .insert(format!("{scope}::uniffi::{}", t.ident));
                for member in &t.items {
                    if let syn::TraitItem::Fn(f) = member {
                        if !syntax::test_only(&f.attrs) {
                            self.report
                                .apis
                                .insert(format!("{scope}::uniffi::{}::{}", t.ident, f.sig.ident));
                        }
                    }
                }
            }
            _ if syntax::uniffi_export(syntax::attributes(item)) => {
                if let Some(name) = syntax::item_name(item) {
                    self.report.apis.insert(format!("{scope}::uniffi::{name}"));
                }
            }
            _ => {}
        }
    }

    pub fn reference(
        &mut self,
        scope: &str,
        file: &str,
        owner: &str,
        path: Vec<String>,
        span: proc_macro2::Span,
    ) {
        let position = span.start();
        self.references.push(RawReference {
            scope: scope.into(),
            file: file.into(),
            owner: owner.into(),
            path,
            line: position.line,
            column: position.column,
        });
    }
}
