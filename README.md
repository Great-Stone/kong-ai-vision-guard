# AI Vision Guard Plugin

The AI Vision Guard plugin classifies multimodal chat images with an OpenAI-compatible vision model and blocks requests that violate your image policy before they reach the LLM upstream.

Use it when [AI Prompt Guard](https://developer.konghq.com/plugins/ai-prompt-guard/) is not enough: Prompt Guard scans **text** with PCRE allow/deny lists; Vision Guard inspects **`image_url` pixel content** (for example chip/SoC floorplans versus ordinary photos).

This plugin is intended to run with [AI Proxy](https://developer.konghq.com/plugins/ai-proxy/) or [AI Proxy Advanced](https://developer.konghq.com/plugins/ai-proxy-advanced/). Priority is `775`, so it runs before AI Prompt Guard (`771`) and AI Proxy.

## How it works

On each request the plugin:

1. Reads the JSON chat body and collects `image_url` parts from `messages`.
2. If there are no images and `skip_if_no_image` is `true`, the request continues unchanged.
3. Sends each image (up to `max_images`) to `vision_url` with `classify_prompt` (`deny_prompts` / `allow_prompts`).
4. Parses the model reply for `VERDICT: ALLOW` or `VERDICT: DENY` (last match wins).

Matching behavior:

- If any image is **DENY**, the caller receives `deny_status` (default `400`) and the request never reaches the upstream LLM.
- If all classified images are **ALLOW**, the request continues to AI Proxy / upstream.
- If the vision call fails and `fail_open` is `false` (default), the caller receives `500`.
- If the vision call fails and `fail_open` is `true`, the request continues.

Response headers (when a decision is made):

| Header | Value |
|--------|--------|
| `X-Vision-Guard-Decision` | `ALLOW`, `DENY`, or `ERROR` |
| `X-Vision-Guard-Model` | Vision model id |

## Best practices

- Pair with AI Prompt Guard for **text** export or jailbreak patterns on the same route; use Vision Guard only for images.
- Keep `classify_prompt.deny_prompts` / `allow_prompts` concrete; the plugin adds a fixed `VERDICT:` suffix for reliable parsing.
- Set `fail_open: false` when a missed classification is worse than a brief outage of the vision endpoint.
- Prefer `data:image/...;base64,...` image URLs in demos so the vision model sees pixels, not filenames.

## Install

1. Make the plugin available on every Kong node that must load it (Control Plane and Data Plane in hybrid mode):

```bash
# From this repository root
luarocks make ai-vision-guard-0.2.0-1.rockspec
```

Or copy `kong/plugins/ai-vision-guard/` into Kong’s Lua path, for example:

```text
<lua_package_path>/kong/plugins/ai-vision-guard/
```

On Docker/Kubernetes, mount that directory into the same path inside the Kong container or image.

2. Enable the plugin name in Kong configuration:

```bash
# kong.conf
plugins = bundled,ai-vision-guard

# or environment
export KONG_PLUGINS="bundled,ai-vision-guard"
```

3. Restart or reload Kong, then confirm the plugin is listed:

```bash
curl -s http://localhost:8001/plugins/enabled \
  | jq '.enabled_plugins | index("ai-vision-guard")'
```

Use your Admin API base URL and auth headers as required by your deployment (RBAC token, Konnect personal access token, and so on).

4. Attach the plugin to a Service or Route (Admin API, decK, or Manager) together with AI Proxy / AI Proxy Advanced. Set at least `vision_url` and `vision_model` to an OpenAI-compatible vision chat-completions endpoint.

### Configure with decK

```yaml
_format_version: "3.0"
services:
  - name: vision-guarded-llm
    url: https://llm.example.com
    plugins:
      - name: ai-vision-guard
        config:
          vision_url: https://vision.example.com/v1/chat/completions
          vision_model: ${{ env "VISION_MODEL" }}
          vision_auth_header_name: Authorization
          vision_auth_header_value: Bearer ${{ env "VISION_API_KEY" }}
          skip_if_no_image: true
          fail_open: false
          deny_status: 400
          tls_verify: true
      - name: ai-proxy-advanced
        config:
          targets:
            - route_type: llm/v1/chat
              model:
                provider: openai
                name: gpt-4o-mini
                options:
                  upstream_url: https://llm.example.com/v1/chat/completions
              auth:
                header_name: Authorization
                header_value: Bearer ${{ env "LLM_API_KEY" }}
    routes:
      - name: vision-guarded-chat
        paths: [/v1/chat/completions]
        strip_path: false
        methods: [POST]
```

```bash
export VISION_MODEL=your-vision-model-id
export VISION_API_KEY=your-vision-api-key
export LLM_API_KEY=your-llm-api-key
deck gateway sync deck.yaml
```

Optional: add [AI Prompt Guard](https://developer.konghq.com/plugins/ai-prompt-guard/) on the same Service or Route for text allow/deny patterns.

## `classify_prompt` examples

`classify_prompt` mirrors [AI Semantic Prompt Guard](https://developer.konghq.com/plugins/ai-semantic-prompt-guard/): set `deny_prompts` and `allow_prompts` only. The plugin adds a fixed preamble, section intros, and `VERDICT:` suffix.

### 1. Semiconductor / chip IP (plugin default)

```yaml
classify_prompt:
  deny_prompts:
    - chip / SoC / IC floorplan or layout (CAD geometry on dark background)
    - VLSI / GDS-style metal layers, blocks, interconnects
    - EDA / floorplanner UI screenshots that display SoC blocks and wiring
    - hardware schematic of chip IP meant for engineering export
  allow_prompts:
    - landscape, wallpaper, nature, ordinary photos
    - marketing banners, infographics, icons, slides about semiconductors
    - factory illustrations that are NOT chip CAD layouts or EDA floorplan screens
```

### 2. Identity documents and face photos

```yaml
classify_prompt:
  deny_prompts:
    - government ID, passport, driver's license, or similar identity documents
    - clear close-up face photos suitable for biometric identification
    - credit/debit cards with visible PAN or CVV
  allow_prompts:
    - ordinary scenes, product photos, memes, and documents without identity data
```

### 3. Internal / confidential screens

```yaml
classify_prompt:
  deny_prompts:
    - internal admin consoles, CRM, ERP, or ticketing UIs with customer records
    - source code, config, or secrets (API keys, tokens, connection strings)
    - confidential slide decks or documents marked Internal / Confidential / Secret
  allow_prompts:
    - public marketing sites, generic UI mockups without real data
    - photos of people or places
```

In decK:

```yaml
config:
  classify_prompt:
    deny_prompts:
      - internal admin consoles with customer records
    allow_prompts:
      - public marketing sites without real data
```

## Configuration

| Field | Description |
|-------|-------------|
| `vision_url` | OpenAI-compatible chat completions URL for the vision model |
| `vision_model` | Vision / multimodal model id |
| `vision_auth_header_name` | Auth header name (default `Authorization`) |
| `vision_auth_header_value` | Full auth value, for example `Bearer <token>` |
| `classify_prompt` | `deny_prompts`, `allow_prompts` only (preamble, intros, VERDICT suffix are fixed) |
| `max_images` | Max `image_url` parts to classify (any DENY wins) |
| `skip_if_no_image` | Pass through when there are no images (default `true`) |
| `fail_open` | Allow traffic if the vision call fails (default `false`) |
| `deny_status` | HTTP status on DENY (default `400`) |
| `max_request_body_size` | Max body size to introspect (bytes; default 25 MiB) |
| `tls_verify` | Verify TLS for `vision_url` (default `false`) |

## Related

- [AI Prompt Guard](https://developer.konghq.com/plugins/ai-prompt-guard/) — text regex allow/deny
- [AI Semantic Prompt Guard](https://developer.konghq.com/plugins/ai-semantic-prompt-guard/) — embedding-based text guard

[한국어](README_KO.md)
