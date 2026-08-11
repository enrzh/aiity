# MCP Recommended Setup

## Goal

Replace the current raw MCP-server list with a guided setup experience for
remote Streamable HTTP MCP servers. Users should understand what MCP is,
choose a suitable provider, complete that provider's browser setup, paste the
endpoint and token into aiity, test the connection, and only then enable tools.

## Scope

The app supports remote HTTP MCP endpoints with optional Bearer tokens. It
does not run desktop `stdio` MCP packages and does not implement Google OAuth
or operate an aiity gateway.

## Recommended Catalog

The catalog contains app-owned metadata rather than preconfigured credentials:

- Provider name, icon, short capability description, and setup URL.
- Whether the provider can expose Google Drive, Calendar, or Gmail.
- A guided prefilled draft with no endpoint or token, because those are issued
  by the provider for the individual user.

Google services are teaching cards, not fake connectable servers. Each card
explains that a compatible hosted MCP provider is needed and opens the selected
provider's setup page.

## User Flow

1. `More -> MCP Server` begins with a compact explanation of MCP and the
   privacy boundary: tools can access data granted to the connected server.
2. The `Recommended` section lists curated remote providers with a direct
   `Set up` action.
3. The provider setup screen gives short ordered steps and opens the provider
   URL in Safari. It retains editable endpoint and token fields for the values
   the user receives there.
4. `Test and load tools` performs the existing MCP initialize, initialized
   notification, and tools/list handshake. A successful result stores schemas
   and enables the profile. A failed result never activates tools.
5. `Custom server` is visually secondary and describes the required
   Streamable HTTP MCP URL and optional Bearer token.

## Architecture

`MCPRecommendation` is static catalog metadata. `MCPServerProfile` remains
the persisted user configuration. Selecting a recommendation produces a new
profile draft; no recommendation URL/token is stored as a user connection.

`MCPServersView` owns catalog presentation and routes to the shared editor.
The editor gets optional recommendation metadata to render setup teaching and
the external setup link. `MCPClient`, Keychain token storage, discovery, and
tool registration remain unchanged.

## Errors and Privacy

The screen states that external MCP providers receive tool arguments and that
the selected provider controls its own authorization. Invalid URLs, HTTP
failures, and empty tool lists keep the profile disabled. Existing Keychain
storage remains the sole location for tokens.

## Tests

- Catalog has direct HTTPS setup URLs and no implicit endpoint/token.
- Google teaching cards cannot be added as ready profiles without user input.
- Recommendation drafts preserve the provider label and remain disabled until
  a successful connection test.
- Existing MCP discovery and namespaced tool-schema tests continue to pass.
