local http = require "resty.http"
local cjson = require "cjson.safe"

local _M = {}

local DENY_INTRO = "DENY only if you can quote any of the following from the image:"
local ALLOW_INTRO = "ALLOW when:"
local PREAMBLE = "You are an OCR checker for Korean insurance documents and customer forms."
local SUFFIX = [[Do NOT invent values for blank cells. Do NOT DENY gray-masked claim-status portals.

First line: quote visible name/010/RRN/address from the image, or NONE.
Last line exactly: VERDICT: DENY  or  VERDICT: ALLOW]]

local FALLBACK_DENY = {
  "FLOORPLAN",
  "CHIP LAYOUT",
  "IC LAYOUT",
  "VLSI",
  "GDS",
  "EDA",
  "NOC",
  "SOC BLOCK",
  "FLOORPLANNER",
}

--- Extract data:/http(s) image URIs from OpenAI chat messages.
-- @param messages table
-- @param opts? { only_last_user?: boolean } when true, only scan the last user message
--   (avoids re-judging older attachments still present in LibreChat chat history).
function _M.extract_image_uris(messages, opts)
  local uris = {}
  if type(messages) ~= "table" then
    return uris
  end

  local only_last_user = opts and opts.only_last_user
  local start_i = 1
  if only_last_user then
    for i = #messages, 1, -1 do
      local msg = messages[i]
      if type(msg) == "table" and msg.role == "user" then
        start_i = i
        break
      end
    end
  end

  for i = start_i, #messages do
    if only_last_user and i > start_i then
      break
    end
    local msg = messages[i]
    if type(msg) == "table" then
      local content = msg.content
      if type(content) == "table" then
        for _, part in ipairs(content) do
          if type(part) == "table" and part.type == "image_url" then
            local image_url = part.image_url
            local url
            if type(image_url) == "string" then
              url = image_url
            elseif type(image_url) == "table" then
              url = image_url.url
            end
            if type(url) == "string" and url ~= "" then
              uris[#uris + 1] = url
            end
          end
        end
      end
    end
  end
  return uris
end

--- Last VERDICT: ALLOW|DENY in text, or nil.
-- ponytail: Lua patterns have no `|`; scan tokens after VERDICT:.
function _M.parse_verdict(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local upper = text:upper()
  local last
  for token in upper:gmatch("VERDICT:%s*(%a+)") do
    if token == "DENY" or token == "ALLOW" then
      last = token
    end
  end
  return last
end

local function fallback_verdict(blob)
  local upper = blob:upper()
  for _, key in ipairs(FALLBACK_DENY) do
    if upper:find(key, 1, true) then
      return "DENY"
    end
  end
  return "ALLOW"
end

local function bullet_lines(items)
  local lines = {}
  for _, item in ipairs(items or {}) do
    if type(item) == "string" and item ~= "" then
      lines[#lines + 1] = "- " .. item
    end
  end
  return lines
end

--- Build VL classifier text from classify_prompt allow/deny parts.
function _M.build_classify_prompt(cp)
  cp = cp or {}
  local parts = { PREAMBLE, "" }

  local deny = cp.deny_prompts
  if type(deny) == "table" and #deny > 0 then
    parts[#parts + 1] = DENY_INTRO
    for _, line in ipairs(bullet_lines(deny)) do
      parts[#parts + 1] = line
    end
    parts[#parts + 1] = ""
  end

  local allow = cp.allow_prompts
  if type(allow) == "table" and #allow > 0 then
    parts[#parts + 1] = ALLOW_INTRO
    for _, line in ipairs(bullet_lines(allow)) do
      parts[#parts + 1] = line
    end
    parts[#parts + 1] = ""
  end

  parts[#parts + 1] = SUFFIX

  return table.concat(parts, "\n")
end

local function choice_blob(body)
  local choices = body and body.choices
  local msg = choices and choices[1] and choices[1].message
  if type(msg) ~= "table" then
    return ""
  end
  local content = msg.content or ""
  local reasoning = msg.reasoning_content or ""
  return tostring(content) .. "\n" .. tostring(reasoning)
end

--- Classify one image URI via vision chat completions.
-- @return result table { decision, reason, model, raw? }, err
function _M.classify_image(conf, data_uri)
  local headers = {
    ["Content-Type"] = "application/json",
  }
  if conf.vision_auth_header_value and conf.vision_auth_header_value ~= "" then
    local name = conf.vision_auth_header_name or "Authorization"
    headers[name] = conf.vision_auth_header_value
  end

  local payload = cjson.encode({
    model = conf.vision_model,
    messages = {
      {
        role = "user",
        content = {
          { type = "text", text = _M.build_classify_prompt(conf.classify_prompt) },
          {
            type = "image_url",
            image_url = {
              url = data_uri,
              -- ponytail: LibreChat-resized forms hallucinate less with high detail
              detail = conf.image_detail or "high",
            },
          },
        },
      },
    },
    max_tokens = conf.max_tokens,
    temperature = conf.temperature,
  })
  if not payload then
    return nil, "failed to encode vision request"
  end

  local client = http.new()
  client:set_timeouts(conf.connect_timeout, conf.send_timeout, conf.read_timeout)

  local res, err = client:request_uri(conf.vision_url, {
    method = "POST",
    body = payload,
    headers = headers,
    ssl_verify = conf.tls_verify,
  })
  if not res then
    return nil, err or "vision request failed"
  end
  if res.status ~= 200 then
    local body = cjson.decode(res.body) or {}
    local msg = body.error and body.error.message or ("vision HTTP " .. tostring(res.status))
    return {
      decision = "ERROR",
      reason = msg,
      model = conf.vision_model,
      raw = body,
    }
  end

  local body = cjson.decode(res.body) or {}
  local blob = choice_blob(body)
  local verdict = _M.parse_verdict(blob)
  if not verdict then
    -- ponytail: no explicit VERDICT → do not apply chip-demo keyword fallback for ambiguous chat refusals
    local upper = blob:upper()
    if upper:find("UNABLE", 1, true) or upper:find("CAN'T", 1, true)
        or upper:find("CANNOT", 1, true) or upper:find("I'M UNABLE", 1, true) then
      verdict = "ALLOW"
    else
      verdict = fallback_verdict(blob)
    end
  end
  return {
    decision = verdict,
    reason = blob:sub(1, 500),
    model = conf.vision_model,
  }
end

--- Judge all images in a chat request body table.
function _M.judge(conf, req)
  local only_last = conf.only_last_user_images
  if only_last == nil then
    only_last = true
  end
  local uris = _M.extract_image_uris(req and req.messages, { only_last_user = only_last })
  if #uris == 0 then
    return {
      decision = "ALLOW",
      reason = "no image parts",
      model = nil,
      images = 0,
    }
  end

  local limit = conf.max_images or #uris
  if limit > #uris then
    limit = #uris
  end

  local details = {}
  for i = 1, limit do
    local result, err = _M.classify_image(conf, uris[i])
    if not result then
      return {
        decision = "ERROR",
        reason = err or "classify failed",
        model = conf.vision_model,
        images = #uris,
        details = details,
      }
    end
    details[#details + 1] = result
    if result.decision == "ERROR" then
      return {
        decision = "ERROR",
        reason = result.reason,
        model = result.model,
        images = #uris,
        details = details,
      }
    end
    if result.decision == "DENY" then
      return {
        decision = "DENY",
        reason = result.reason or "vision model denied image",
        model = result.model,
        images = #uris,
        details = details,
      }
    end
  end

  local last = details[#details]
  return {
    decision = "ALLOW",
    reason = last and last.reason or "allowed",
    model = last and last.model or conf.vision_model,
    images = #uris,
    details = details,
  }
end

return _M
