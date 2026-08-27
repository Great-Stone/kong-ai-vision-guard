local typedefs = require "kong.db.schema.typedefs"

local DEFAULT_DENY_PROMPTS = {
  "chip / SoC / IC floorplan or layout (CAD geometry on dark background)",
  "VLSI / GDS-style metal layers, blocks, interconnects",
  "EDA / floorplanner UI screenshots that display SoC blocks (CPU, GPU, LLC, NoC, modem, etc.) and wiring",
  "hardware schematic of chip IP meant for engineering export",
}
local DEFAULT_ALLOW_PROMPTS = {
  "landscape, wallpaper, nature, ordinary photos",
  "marketing banners, infographics, icons, slides about semiconductors or fabless/foundry concepts",
  "factory illustrations that are NOT chip CAD layouts or EDA floorplan screens",
}

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
              type = "record",
              fields = {
                { deny_prompts = {
                    type = "array",
                    default = DEFAULT_DENY_PROMPTS,
                    len_max = 50,
                    description = "DENY criteria (one bullet each; intro line is added by the plugin).",
                    elements = {
                      type = "string",
                      len_min = 1,
                    },
                } },
                { allow_prompts = {
                    type = "array",
                    default = DEFAULT_ALLOW_PROMPTS,
                    len_max = 50,
                    description = "ALLOW criteria (one bullet each; intro line is added by the plugin).",
                    elements = {
                      type = "string",
                      len_min = 1,
                    },
                } },
              },
          } },
          { max_images = {
              type = "integer",
              default = 4,
              gt = 0,
              description = "Classify at most this many image_url parts (any DENY wins).",
          } },
          { only_last_user_images = {
              type = "boolean",
              default = true,
              required = true,
              description = "If true, only images in the last user message are classified (chat history).",
          } },
          { image_detail = {
              type = "string",
              default = "high",
              one_of = { "low", "high", "auto" },
              description = "OpenAI image detail passed to the vision classifier.",
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
  entity_checks = {
    {
      at_least_one_of = {
        "config.classify_prompt.deny_prompts",
        "config.classify_prompt.allow_prompts",
      },
    },
  },
}
