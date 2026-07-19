# Use GitHub raw as the production feed

CodexRadar uses `https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml` as the Production Feed to avoid introducing a custom domain or separate hosting service for the first automatic-update release. Because this URL is embedded in installed applications, it is a long-term compatibility contract: repository moves or renames must keep the old URL serving a valid signed migration feed for existing clients.
