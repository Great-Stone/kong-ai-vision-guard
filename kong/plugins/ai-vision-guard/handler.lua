local classify = require "kong.plugins.ai-vision-guard.classify"

local AiVisionGuardHandler = {
  PRIORITY = 775,
  VERSION = "0.2.0",
}

local function set_ctx(decision, model, reason)
  kong.ctx.plugin.decision = decision
  kong.ctx.plugin.model = model
  kong.ctx.plugin.reason = reason
end

local function deny_exit(conf, verdict)
  set_ctx("DENY", verdict.model, verdict.reason)
  return kong.response.exit(conf.deny_status or 400, {
    error = {
      message = "image policy blocked by vision LLM",
      reason = verdict.reason,
      model = verdict.model,
    },
    decision = "DENY",
    model = verdict.model,
  }, {
    ["X-Vision-Guard-Decision"] = "DENY",
    ["X-Vision-Guard-Model"] = tostring(verdict.model or ""),
    ["X-Vision-Guard-Reason"] = tostring(verdict.reason or ""):gsub("[\r\n]+", " "):sub(1, 200),
  })
end

local function error_exit(conf, reason, model)
  if conf.fail_open then
    kong.log.warn("[ai-vision-guard] fail_open: ", reason)
    set_ctx("ERROR", model, reason)
    return
  end
  set_ctx("ERROR", model, reason)
  return kong.response.exit(500, {
    error = { message = "vision judge failed: " .. tostring(reason) },
    decision = "ERROR",
  }, {
    ["X-Vision-Guard-Decision"] = "ERROR",
  })
end

function AiVisionGuardHandler:access(conf)
  local body, err = kong.request.get_body("application/json", nil, conf.max_request_body_size)
  if not body then
    if conf.skip_if_no_image then
      kong.log.debug("[ai-vision-guard] skip: no json body (", err or "nil", ")")
      return
    end
    return error_exit(conf, err or "invalid request body", conf.vision_model)
  end

  local only_last = conf.only_last_user_images
  if only_last == nil then
    only_last = true
  end
  local uris = classify.extract_image_uris(body.messages, { only_last_user = only_last })
  if #uris == 0 then
    if conf.skip_if_no_image then
      return
    end
    set_ctx("ALLOW", nil, "no image parts")
    return
  end

  local verdict = classify.judge(conf, body)
  if verdict.decision == "ERROR" then
    return error_exit(conf, verdict.reason, verdict.model)
  end
  if verdict.decision == "DENY" then
    return deny_exit(conf, verdict)
  end

  set_ctx("ALLOW", verdict.model, verdict.reason)
  kong.log.info("[ai-vision-guard] ALLOW images=", tostring(verdict.images),
                " model=", tostring(verdict.model))
end

function AiVisionGuardHandler:header_filter(_)
  local decision = kong.ctx.plugin.decision
  if not decision then
    return
  end
  kong.response.set_header("X-Vision-Guard-Decision", decision)
  if kong.ctx.plugin.model then
    kong.response.set_header("X-Vision-Guard-Model", kong.ctx.plugin.model)
  end
  local reason = kong.ctx.plugin.reason
  if reason and reason ~= "" then
    -- single-line header for debugging LibreChat (no newlines)
    local one = tostring(reason):gsub("[\r\n]+", " "):sub(1, 200)
    kong.response.set_header("X-Vision-Guard-Reason", one)
  end
end

return AiVisionGuardHandler
