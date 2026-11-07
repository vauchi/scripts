// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use serde::{Deserialize, Serialize};
use syn::{
    spanned::Spanned,
    visit::{self, Visit},
    BinOp, Expr,
};

#[derive(Debug, Deserialize)]
pub struct SourceFile {
    pub path: String,
    pub source: String,
}

#[derive(Debug, Serialize)]
pub struct FunctionComplexity {
    pub path: String,
    pub name: String,
    pub line: usize,
    pub column: usize,
    pub cyclomatic: u32,
    pub max_nesting: u32,
    pub macro_invocations: usize,
}

#[derive(Debug, Serialize)]
pub struct ParseFailure {
    pub path: String,
    pub error: String,
}

#[derive(Debug, Default, Serialize)]
pub struct ComplexityReport {
    pub files_analyzed: usize,
    pub macro_invocations: usize,
    pub functions: Vec<FunctionComplexity>,
    pub failures: Vec<ParseFailure>,
}

struct Measure {
    cyclomatic: u32,
    nesting: u32,
    max_nesting: u32,
    macros: usize,
}

impl Measure {
    fn new() -> Self {
        Self {
            cyclomatic: 1,
            nesting: 0,
            max_nesting: 0,
            macros: 0,
        }
    }
}

impl<'ast> Visit<'ast> for Measure {
    fn visit_item(&mut self, _: &'ast syn::Item) {}

    fn visit_expr(&mut self, node: &'ast Expr) {
        let decision = matches!(
            node,
            Expr::If(_) | Expr::ForLoop(_) | Expr::While(_) | Expr::Loop(_)
        );
        let branching = decision || matches!(node, Expr::Match(_));
        if decision {
            self.cyclomatic += 1;
        }
        match node {
            Expr::Closure(_) => return,
            Expr::Match(m) => {
                self.cyclomatic += m.arms.len().saturating_sub(1) as u32;
                self.cyclomatic += m.arms.iter().filter(|a| a.guard.is_some()).count() as u32;
            }
            Expr::Binary(b) if matches!(b.op, BinOp::And(_) | BinOp::Or(_)) => self.cyclomatic += 1,
            Expr::Try(_) => self.cyclomatic += 1,
            _ => {}
        }
        if branching {
            self.nesting += 1;
            self.max_nesting = self.max_nesting.max(self.nesting);
        }
        visit::visit_expr(self, node);
        if branching {
            self.nesting -= 1;
        }
    }

    fn visit_macro(&mut self, _: &'ast syn::Macro) {
        self.macros += 1;
    }
}

struct Functions<'a> {
    path: &'a str,
    functions: Vec<FunctionComplexity>,
    macros: usize,
}

impl Functions<'_> {
    fn add(&mut self, name: String, span: proc_macro2::Span, measure: Measure) {
        let start = span.start();
        self.functions.push(FunctionComplexity {
            path: self.path.into(),
            name,
            line: start.line,
            column: start.column + 1,
            cyclomatic: measure.cyclomatic,
            max_nesting: measure.max_nesting,
            macro_invocations: measure.macros,
        });
    }

    fn block(&mut self, name: String, span: proc_macro2::Span, block: &syn::Block) {
        let mut measure = Measure::new();
        measure.visit_block(block);
        self.add(name, span, measure);
    }
}

impl<'ast> Visit<'ast> for Functions<'_> {
    fn visit_item_fn(&mut self, node: &'ast syn::ItemFn) {
        self.block(node.sig.ident.to_string(), node.span(), &node.block);
        visit::visit_item_fn(self, node);
    }

    fn visit_impl_item_fn(&mut self, node: &'ast syn::ImplItemFn) {
        self.block(node.sig.ident.to_string(), node.span(), &node.block);
        visit::visit_impl_item_fn(self, node);
    }

    fn visit_trait_item_fn(&mut self, node: &'ast syn::TraitItemFn) {
        if let Some(block) = &node.default {
            self.block(node.sig.ident.to_string(), node.span(), block);
        }
        visit::visit_trait_item_fn(self, node);
    }

    fn visit_expr_closure(&mut self, node: &'ast syn::ExprClosure) {
        let mut measure = Measure::new();
        measure.visit_expr(&node.body);
        self.add("closure".into(), node.span(), measure);
        visit::visit_expr_closure(self, node);
    }

    fn visit_macro(&mut self, _: &'ast syn::Macro) {
        self.macros += 1;
    }
}

pub fn analyze_sources(files: &[SourceFile]) -> ComplexityReport {
    let mut report = ComplexityReport::default();
    for file in files {
        match syn::parse_file(&file.source) {
            Ok(parsed) => {
                let mut functions = Functions {
                    path: &file.path,
                    functions: Vec::new(),
                    macros: 0,
                };
                functions.visit_file(&parsed);
                report.files_analyzed += 1;
                report.macro_invocations += functions.macros;
                report.functions.extend(functions.functions);
            }
            Err(error) => report.failures.push(ParseFailure {
                path: file.path.clone(),
                error: error.to_string(),
            }),
        }
    }
    report
        .functions
        .sort_by(|a, b| (&a.path, a.line, a.column).cmp(&(&b.path, b.line, b.column)));
    report
}
