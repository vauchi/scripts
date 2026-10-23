// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use std::path::{Path, PathBuf};
use syn::{parse::Parser, punctuated::Punctuated, Expr, Lit, Token};

pub(crate) fn resolve(
    mac: &syn::Macro,
    source: &Path,
    file: &Path,
    generated: Option<&Path>,
) -> Result<(PathBuf, PathBuf), String> {
    let expression: Expr = syn::parse2(mac.tokens.clone()).map_err(|e| e.to_string())?;
    if let Expr::Lit(lit) = &expression {
        if let Lit::Str(path) = &lit.lit {
            return Ok((
                source.into(),
                file.parent()
                    .ok_or("missing include parent")?
                    .join(path.value()),
            ));
        }
    }
    if let Expr::Macro(expr) = expression {
        if expr.mac.path.is_ident("concat") {
            let args = Punctuated::<Expr, Token![,]>::parse_terminated
                .parse2(expr.mac.tokens)
                .map_err(|e| e.to_string())?;
            let args: Vec<_> = args.iter().collect();
            if let [Expr::Macro(env), Expr::Lit(suffix)] = args.as_slice() {
                if env.mac.path.is_ident("env") {
                    let key: syn::LitStr =
                        syn::parse2(env.mac.tokens.clone()).map_err(|e| e.to_string())?;
                    if key.value() == "OUT_DIR" {
                        if let Lit::Str(suffix) = &suffix.lit {
                            let generated = generated
                                .ok_or("include! requires freshly generated source directory")?;
                            return Ok((
                                generated.into(),
                                generated.join(suffix.value().trim_start_matches('/')),
                            ));
                        }
                    }
                }
            }
        }
    }
    Err(format!(
        "{}: unsupported include! expression",
        file.display()
    ))
}
