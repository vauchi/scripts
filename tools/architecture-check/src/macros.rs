// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use proc_macro2::{Group, TokenStream, TokenTree};
use syn::Item;

// Expand only the single `$name:ident` rule used for identifier newtypes.
// Other macros retain explicit-token scanning; unresolved generated names fail.
pub(crate) fn expand(mac: &syn::Macro, items: &[Item]) -> Result<Option<Vec<Item>>, String> {
    let Some(definition) = items.iter().find_map(|item| match item {
        Item::Macro(m)
            if m.mac.path.is_ident("macro_rules")
                && m.ident.as_ref().is_some_and(|id| mac.path.is_ident(id)) =>
        {
            Some(m)
        }
        _ => None,
    }) else {
        return Ok(None);
    };
    let tokens: Vec<_> = definition.mac.tokens.clone().into_iter().collect();
    let [TokenTree::Group(matcher), TokenTree::Punct(eq), TokenTree::Punct(gt), TokenTree::Group(body), rest @ ..] =
        tokens.as_slice()
    else {
        return Ok(None);
    };
    if eq.as_char() != '='
        || gt.as_char() != '>'
        || rest.len() > 1
        || rest
            .first()
            .is_some_and(|t| !matches!(t, TokenTree::Punct(p) if p.as_char() == ';'))
    {
        return Ok(None);
    }
    let pattern: Vec<_> = matcher.stream().into_iter().collect();
    let [TokenTree::Punct(dollar), TokenTree::Ident(variable), TokenTree::Punct(colon), TokenTree::Ident(kind)] =
        pattern.as_slice()
    else {
        return Ok(None);
    };
    if dollar.as_char() != '$' || colon.as_char() != ':' || kind != "ident" {
        return Ok(None);
    }
    let argument: syn::Ident = syn::parse2(mac.tokens.clone()).map_err(|e| e.to_string())?;
    let expanded = substitute(body.stream(), &variable.to_string(), &argument)?;
    let parsed: syn::File = syn::parse2(expanded).map_err(|e| format!("macro expansion: {e}"))?;
    if parsed
        .items
        .iter()
        .any(|i| matches!(i, Item::Macro(m) if m.mac.path == mac.path))
    {
        return Err("recursive identifier macro".into());
    }
    Ok(Some(parsed.items))
}

fn substitute(
    input: TokenStream,
    variable: &str,
    argument: &syn::Ident,
) -> Result<TokenStream, String> {
    let mut output = TokenStream::new();
    let mut tokens = input.into_iter();
    while let Some(token) = tokens.next() {
        let replacement = match token {
            TokenTree::Punct(p) if p.as_char() == '$' => match tokens.next() {
                Some(TokenTree::Ident(id)) if id == variable => TokenTree::Ident(argument.clone()),
                _ => return Err("unsupported macro substitution".into()),
            },
            TokenTree::Group(group) => {
                let mut replaced = Group::new(
                    group.delimiter(),
                    substitute(group.stream(), variable, argument)?,
                );
                replaced.set_span(group.span());
                TokenTree::Group(replaced)
            }
            other => other,
        };
        output.extend([replacement]);
    }
    Ok(output)
}
