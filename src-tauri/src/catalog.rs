use std::sync::OnceLock;
use serde::Deserialize;
use crate::models::{CatalogService, CategoryMeta};

#[derive(Debug, Deserialize)]
struct CatalogBundle {
    categories: Vec<CategoryMeta>,
    services: Vec<CatalogService>,
}

static CATALOG_DATA: OnceLock<CatalogBundle> = OnceLock::new();

fn bundle() -> &'static CatalogBundle {
    CATALOG_DATA.get_or_init(|| {
        const RAW: &str = include_str!("../assets/catalog.json");
        serde_json::from_str(RAW).expect("embedded catalog.json must be valid")
    })
}

pub fn categories() -> &'static [CategoryMeta] {
    &bundle().categories
}

pub fn services() -> &'static [CatalogService] {
    &bundle().services
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use crate::url_utils::normalize_service_url;

    #[test]
    fn embedded_catalog_is_complete_and_valid() {
        let cats = categories();
        let svcs = services();
        assert_eq!(cats.len(), 7);
        assert_eq!(svcs.len(), 60);
        assert!(!svcs.iter().any(|s| s.id == "x"), "X must be removed from catalog");

        let cat_ids: HashSet<&str> = cats.iter().map(|c| c.id.as_str()).collect();
        let mut seen = HashSet::new();
        for svc in svcs {
            assert!(seen.insert(svc.id.as_str()), "Duplicate id: {}", svc.id);
            assert!(cat_ids.contains(svc.category.as_str()));
            assert!(normalize_service_url(&svc.url).unwrap().starts_with("https://"));
            assert!(normalize_service_url(&svc.home_url).unwrap().starts_with("https://"));
        }
    }
}
