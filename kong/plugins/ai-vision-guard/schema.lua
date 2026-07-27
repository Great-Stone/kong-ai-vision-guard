local typedefs = require "kong.db.schema.typedefs"

local DEFAULT_PROMPT = [[You are an export-control image classifier for semiconductor IP.

DENY if the image shows proprietary chip design artifacts, including:
- chip / SoC / IC floorplan or layout (CAD geometry on dark background)
- VLSI / GDS-style metal layers, blocks, interconnects
- EDA / floorplanner UI screenshots that display SoC blocks (CPU, GPU, LLC, NoC, modem, etc.) and wiring
- hardware schematic of chip IP meant for engineering export

ALLOW for everything else, including:
- landscape, wallpaper, nature, ordinary photos
- marketing banners, infographics, icons, slides about semiconductors or fabless/foundry concepts
- factory illustrations that are NOT chip CAD layouts or EDA floorplan screens

Be brief. End with exactly: VERDICT: DENY  or  VERDICT: ALLOW]]

return {
  name = "ai-vision-guard",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { vision_url = {
              type = "string",
              required = true,
              description = "OpenAI-compatible chat completions URL for the vision model.",
          } },
          { vision_model = {
              type = "string",
              required = true,
              description = "Vision / multimodal model id.",
          } },
          { vision_auth_header_name = {
              type = "string",
              default = "Authorization",
          } },
          { vision_auth_header_value = {
              type = "string",
              required = false,
              encrypted = true,
              referenceable = true,
              description = "Full auth header value, e.g. Bearer <token>.",
          } },
          { classify_prompt = {
              type = "string",
              default = DEFAULT_PROMPT,
              len_min = 1,
          } },
          { max_images = {
              type = "integer",
              default = 4,
              gt = 0,
              description = "Classify at most this many image_url parts (any DENY wins).",
          } },
          { skip_if_no_image = {
              type = "boolean",
              default = true,
              required = true,
          } },
          { fail_open = {
              type = "boolean",
              default = false,
              required = true,
              description = "If true, vision HTTP/parse errors allow the request through.",
          } },
          { deny_status = {
              type = "integer",
              default = 400,
              between = { 400, 499 },
          } },
          { max_tokens = {
              type = "integer",
              default = 512,
              gt = 0,
          } },
          { temperature = {
              type = "number",
              default = 0,
              between = { 0, 2 },
          } },
          { connect_timeout = { type = "number", default = 10000, gt = 0 } },
          { send_timeout = { type = "number", default = 10000, gt = 0 } },
          { read_timeout = { type = "number", default = 180000, gt = 0 } },
          { max_request_body_size = {
              type = "integer",
              default = 26214400,
              gt = -1,
              description = "Max introspected body size (bytes). 0 = unlimited (still limited by nginx).",
          } },
          { tls_verify = {
              type = "boolean",
              default = false,
              required = true,
          } },
        },
    } },
  },
}
