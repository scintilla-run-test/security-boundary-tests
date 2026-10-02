async fn exchange(
    State(state): State<AppState>,
    Json(request): Json<ProviderPairRequest>,
) -> Result<Json<ProviderPairResponse>, AuthError> {
    validate_request(&request)?;
    let db = state.db.as_ref().ok_or(AuthError::Unavailable)?;
    let (supabase, neon) = verify_pair(&state, &request).await?;
    let (supabase_identity, neon_identity) = tokio::join!(
        db.upsert_supabase_identity(&supabase),
        upsert_neon(db, &neon),
    );
    let identity = require_same_principal(supabase_identity?, neon_identity?)?;
    issue_pair_session(&state, identity, &supabase, &neon).await
}
