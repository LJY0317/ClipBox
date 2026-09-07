//! Shared core primitives for ClipBox.

pub const APP_NAME: &str = "ClipBox";

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ArchiveIdentity {
    pub site: String,
    pub media_id: String,
}

impl ArchiveIdentity {
    pub fn new(site: impl Into<String>, media_id: impl Into<String>) -> Self {
        Self {
            site: site.into(),
            media_id: media_id.into(),
        }
    }
}

/// Conservative cross-platform filename sanitization.
/// Spaces are intentionally preserved for human readability.
pub fn sanitize_filename_component(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    for ch in input.chars() {
        let forbidden = matches!(ch, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*')
            || ch.is_control();
        output.push(if forbidden { '_' } else { ch });
    }

    let trimmed = output.trim().trim_end_matches(['.', ' ']).trim();
    if trimmed.is_empty() {
        "untitled".to_owned()
    } else {
        trimmed.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn archive_identity_keeps_large_ids_as_text() {
        let identity = ArchiveIdentity::new("example", "001234567890123456789");
        assert_eq!(identity.media_id, "001234567890123456789");
    }

    #[test]
    fn filename_sanitizer_preserves_spaces() {
        assert_eq!(
            sanitize_filename_component("A readable title [abc123]"),
            "A readable title [abc123]"
        );
    }

    #[test]
    fn filename_sanitizer_replaces_forbidden_characters() {
        assert_eq!(sanitize_filename_component("A/B:C?D*E"), "A_B_C_D_E");
    }
}
