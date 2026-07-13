// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
//
// SPDX-License-Identifier: GPL-3.0-or-later

use zeroize::{Zeroize, ZeroizeOnDrop};

struct MarkerOnlySecret([u8; 32]);

impl Zeroize for MarkerOnlySecret {
    fn zeroize(&mut self) {
        self.0.zeroize();
    }
}

// ruleid: vauchi-no-manual-zeroize-on-drop
impl ZeroizeOnDrop for MarkerOnlySecret {}

// ok: vauchi-no-manual-zeroize-on-drop
#[derive(Zeroize, ZeroizeOnDrop)]
struct DerivedDropSecret([u8; 32]);

struct WrapperWithSelfZeroizingField(zeroize::Zeroizing<[u8; 32]>);

// ok: vauchi-no-manual-zeroize-on-drop
// nosemgrep: vauchi-no-manual-zeroize-on-drop — field owns its drop zeroization
impl ZeroizeOnDrop for WrapperWithSelfZeroizingField {}
