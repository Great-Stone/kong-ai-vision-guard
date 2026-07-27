package = "ai-vision-guard"
version = "0.1.0-1"

source = {
  url = "git+https://github.com/Great-Stone/kong-ai-vision-guard.git",
  tag = "0.1.0",
}

description = {
  summary = "Multimodal vision LLM image policy guard for Kong Gateway",
  detailed = [[
    Inspects OpenAI chat `image_url` parts, classifies them with an
    OpenAI-compatible vision model, and blocks DENY verdicts before
    ai-proxy. Intended for export-control / IP image policies that
    ai-prompt-guard (regex) cannot cover.
  ]],
  license = "MIT",
}

dependencies = {
  "lua >= 5.1",
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.ai-vision-guard.handler"]  = "kong/plugins/ai-vision-guard/handler.lua",
    ["kong.plugins.ai-vision-guard.schema"]   = "kong/plugins/ai-vision-guard/schema.lua",
    ["kong.plugins.ai-vision-guard.classify"] = "kong/plugins/ai-vision-guard/classify.lua",
  },
}
