// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use crate::collect::{Import, Index};
use proc_macro2::{TokenStream, TokenTree};
use quote::ToTokens;
use syn::{
    parse::Parser,
    spanned::Spanned,
    visit::{self, Visit},
    Attribute, Item, Meta, Token, UseTree,
};

pub(crate) fn attributes(item: &Item) -> &[Attribute] {
    match item {
        Item::Const(i) => &i.attrs,
        Item::Enum(i) => &i.attrs,
        Item::ExternCrate(i) => &i.attrs,
        Item::Fn(i) => &i.attrs,
        Item::ForeignMod(i) => &i.attrs,
        Item::Impl(i) => &i.attrs,
        Item::Macro(i) => &i.attrs,
        Item::Mod(i) => &i.attrs,
        Item::Static(i) => &i.attrs,
        Item::Struct(i) => &i.attrs,
        Item::Trait(i) => &i.attrs,
        Item::TraitAlias(i) => &i.attrs,
        Item::Type(i) => &i.attrs,
        Item::Union(i) => &i.attrs,
        Item::Use(i) => &i.attrs,
        _ => &[],
    }
}

pub(crate) fn item_name(item: &Item) -> Option<String> {
    Some(match item {
        Item::Const(i) => i.ident.to_string(),
        Item::Enum(i) => i.ident.to_string(),
        Item::Fn(i) => i.sig.ident.to_string(),
        Item::Mod(i) => i.ident.to_string(),
        Item::Static(i) => i.ident.to_string(),
        Item::Struct(i) => i.ident.to_string(),
        Item::Trait(i) => i.ident.to_string(),
        Item::TraitAlias(i) => i.ident.to_string(),
        Item::Type(i) => i.ident.to_string(),
        Item::Union(i) => i.ident.to_string(),
        Item::Impl(i) => format!("impl[{}]", i.self_ty.to_token_stream()),
        Item::Macro(i) => i.ident.as_ref()?.to_string(),
        _ => return None,
    })
}

// None means an unknown production configuration: retain both branches.
fn cfg_value(meta: &Meta) -> Option<bool> {
    match meta {
        Meta::Path(p) if p.is_ident("test") => Some(false),
        Meta::NameValue(n) if n.path.is_ident("feature") => {
            if let syn::Expr::Lit(l) = &n.value {
                if let syn::Lit::Str(s) = &l.lit {
                    if matches!(s.value().as_str(), "testing" | "test-support" | "test-kdf") {
                        return Some(false);
                    }
                }
            }
            None
        }
        Meta::List(l) => {
            let values = syn::punctuated::Punctuated::<Meta, Token![,]>::parse_terminated
                .parse2(l.tokens.clone())
                .ok()?;
            let values: Vec<_> = values.iter().map(cfg_value).collect();
            if l.path.is_ident("not") && values.len() == 1 {
                return values[0].map(|v| !v);
            }
            if l.path.is_ident("all") {
                if values.contains(&Some(false)) {
                    Some(false)
                } else if values.iter().all(|v| *v == Some(true)) {
                    Some(true)
                } else {
                    None
                }
            } else if l.path.is_ident("any") {
                if values.contains(&Some(true)) {
                    Some(true)
                } else if values.iter().all(|v| *v == Some(false)) {
                    Some(false)
                } else {
                    None
                }
            } else {
                None
            }
        }
        _ => None,
    }
}

pub(crate) fn test_only(attrs: &[Attribute]) -> bool {
    attrs.iter().any(|a| {
        a.path().is_ident("cfg")
            && a.parse_args::<Meta>().ok().as_ref().and_then(cfg_value) == Some(false)
    })
}

pub(crate) fn module_path(attrs: &[Attribute]) -> Result<Option<String>, String> {
    for attr in attrs {
        if attr.path().is_ident("path") {
            if let Meta::NameValue(n) = &attr.meta {
                if let syn::Expr::Lit(l) = &n.value {
                    if let syn::Lit::Str(s) = &l.lit {
                        return Ok(Some(s.value()));
                    }
                }
            }
            return Err("invalid module path attribute".into());
        }
        if attr.path().is_ident("cfg_attr") && attr.to_token_stream().to_string().contains("path") {
            return Err("conditional #[path] requires explicit analyzer support".into());
        }
    }
    Ok(None)
}

pub(crate) fn uniffi_export(attrs: &[Attribute]) -> bool {
    attrs.iter().any(|a| {
        a.path()
            .segments
            .iter()
            .map(|s| s.ident.to_string())
            .collect::<Vec<_>>()
            == ["uniffi", "export"]
    })
}

pub(crate) struct Collector<'a> {
    pub index: &'a mut Index,
    pub scope: String,
    pub file: String,
    pub owner: String,
    pub error: Option<String>,
}

impl Collector<'_> {
    fn import(&mut self, tree: &UseTree, prefix: Vec<String>) {
        match tree {
            UseTree::Path(p) => {
                let mut path = prefix;
                path.push(p.ident.to_string());
                self.import(&p.tree, path);
            }
            UseTree::Group(g) => {
                for child in &g.items {
                    self.import(child, prefix.clone());
                }
            }
            UseTree::Glob(_) => {
                self.index
                    .globs
                    .entry(self.scope.clone())
                    .or_default()
                    .push(Import {
                        scope: self.scope.clone(),
                        path: prefix.clone(),
                    });
                self.index
                    .reference(&self.scope, &self.file, &self.owner, prefix, tree.span());
            }
            UseTree::Name(_) | UseTree::Rename(_) => {
                let (name, alias) = match tree {
                    UseTree::Name(n) => (n.ident.to_string(), n.ident.to_string()),
                    UseTree::Rename(n) => (n.ident.to_string(), n.rename.to_string()),
                    _ => unreachable!(),
                };
                let mut path = prefix;
                if name != "self" {
                    path.push(name);
                }
                let alias = if alias == "self" {
                    path.last().cloned().unwrap_or_default()
                } else {
                    alias
                };
                self.index
                    .imports
                    .entry(format!("{}::{alias}", self.scope))
                    .or_default()
                    .push(Import {
                        scope: self.scope.clone(),
                        path: path.clone(),
                    });
                self.index
                    .reference(&self.scope, &self.file, &self.owner, path, tree.span());
            }
        }
    }

    fn macro_paths(&mut self, tokens: TokenStream) {
        let tokens: Vec<_> = tokens.into_iter().collect();
        let mut i = 0;
        while i < tokens.len() {
            if let TokenTree::Group(g) = &tokens[i] {
                self.macro_paths(g.stream());
            }
            if let TokenTree::Ident(first) = &tokens[i] {
                let mut path = vec![first.to_string()];
                let mut end = i + 1;
                while end + 2 < tokens.len()
                    && matches!(&tokens[end], TokenTree::Punct(p) if p.as_char() == ':')
                    && matches!(&tokens[end+1], TokenTree::Punct(p) if p.as_char() == ':')
                {
                    if let TokenTree::Ident(next) = &tokens[end + 2] {
                        path.push(next.to_string());
                        end += 3;
                    } else {
                        break;
                    }
                }
                if path.len() > 1 {
                    self.index
                        .reference(&self.scope, &self.file, &self.owner, path, first.span());
                    i = end;
                    continue;
                }
            }
            i += 1;
        }
    }
}

impl<'ast> Visit<'ast> for Collector<'_> {
    fn visit_item(&mut self, item: &'ast Item) {
        if test_only(attributes(item)) {
            return;
        }
        let previous = self.owner.clone();
        if let Some(name) = item_name(item) {
            self.owner = format!("{}::{name}", self.scope);
        }
        visit::visit_item(self, item);
        self.owner = previous;
    }
    fn visit_item_use(&mut self, item: &'ast syn::ItemUse) {
        self.import(&item.tree, vec![]);
    }
    fn visit_path(&mut self, path: &'ast syn::Path) {
        self.index.reference(
            &self.scope,
            &self.file,
            &self.owner,
            path.segments.iter().map(|s| s.ident.to_string()).collect(),
            path.span(),
        );
        visit::visit_path(self, path);
    }
    fn visit_impl_item_fn(&mut self, item: &'ast syn::ImplItemFn) {
        if test_only(&item.attrs) {
            return;
        }
        let previous = self.owner.clone();
        self.owner = format!("{}::{}", self.owner, item.sig.ident);
        visit::visit_impl_item_fn(self, item);
        self.owner = previous;
    }
    fn visit_attribute(&mut self, _: &'ast Attribute) {}
    fn visit_visibility(&mut self, _: &'ast syn::Visibility) {}
    fn visit_macro(&mut self, mac: &'ast syn::Macro) {
        if mac.path.is_ident("include") {
            self.error = Some(format!(
                "{}: include! requires explicit source expansion",
                self.file
            ));
            return;
        }
        self.visit_path(&mac.path);
        self.macro_paths(mac.tokens.clone());
    }
}
