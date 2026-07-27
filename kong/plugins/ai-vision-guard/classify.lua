local http = require "resty.http"
local cjson = require "cjson.safe"

local _M = {}

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
function _M.extract_image_uris(messages)
  local uris = {}
  if type(messages) ~= "table" then
    return uris
  end
  for _, msg in ipairs(messages) do
    if type(msg) == "table" then
      local content = msg.content
      if type(content) == "table" then
        for _, part in ipairs(content) do
          if type(part) == "table" and part.type == "image_url" then
            local url = part.image_url and part.image_url.url
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
          { type = "text", text = conf.classify_prompt },
          { type = "image_url", image_url = { url = data_uri } },
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
  local verdict = _M.parse_verdict(blob) or fallback_verdict(blob)
  return {
    decision = verdict,
    reason = blob:sub(1, 500),
    model = conf.vision_model,
  }
end

--- Judge all images in a chat request body table.
function _M.judge(conf, req)
  local uris = _M.extract_image_uris(req and req.messages)
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
