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

    translator = {
        -- OpenAI-compatible providers include OpenRouter, OpenAI, SiliconFlow,
        -- DeepSeek-compatible gateways, local one-api/new-api, etc.
        provider = "openai_compatible",
        openai_compatible = {
            -- OpenRouter example:
            base_url = "https://openrouter.ai/api/v1/chat/completions",
            api_key = "",
            model = "qwen/qwen3-14b:free",
            max_tokens = 8192,
            temperature = 0.2,
            extra_headers = {
                ["HTTP-Referer"] = "https://github.com/rollingshmily/appstore.koplugin",
                ["X-Title"] = "appstore.koplugin",
            },
        },
        -- Set provider = "mymemory" only as a no-key fallback.
    },
}

