pub struct NeonRegistry {
    by_issuer: HashMap<String, Arc<NeonVerifier>>,
}

impl NeonRegistry {
    pub fn from_environment() -> Result<Self, anyhow::Error> {
        let raw = std::env::var("AUTH_NEON_PROJECTS")
            .or_else(|_| std::env::var("AUTH_NEON_AUTH_REGISTRY"))
            .unwrap_or_default();
        if raw.trim().is_empty() {
            return Ok(Self {
                by_issuer: HashMap::new(),
            });
        }

        let projects = serde_json::from_str::<Vec<NeonAuthProject>>(&raw)?;
        if projects.len() > MAX_PROJECTS {
            anyhow::bail!("AUTH_NEON_PROJECTS exceeds {MAX_PROJECTS} entries");
        }

        let mut by_issuer = HashMap::new();
        for project in projects {
            let verifier = Arc::new(NeonVerifier::new(project.normalize()?));
            if by_issuer
                .insert(verifier.issuer().to_owned(), verifier)
                .is_some()
            {
                anyhow::bail!("duplicate Neon JWT issuer");
            }
        }
        Ok(Self { by_issuer })
    }
}
