-- User-editable configuration for AppStore plugin.
-- Fill in your personal access tokens (PAT) here to raise API limits.
-- Example for GitHub: generate a PAT with "public_repo" scope and paste it below.
return {
    auth = {
        github = {
            type = "github",
            token = "",
        },
    },
    -- GitHub proxy for users in regions with restricted access to GitHub.
    -- Default: gh-proxy.com (no registration required).
    -- Set to empty string "" to connect directly.
    proxy_url = "https://gh-proxy.com",
}

