# AI Vision Guard 플러그인

AI Vision Guard는 OpenAI 호환 비전 모델로 멀티모달 채팅의 이미지를 분류하고, 정책에 맞지 않으면 LLM upstream에 도달하기 전에 요청을 차단합니다.

[AI Prompt Guard](https://developer.konghq.com/plugins/ai-prompt-guard/)만으로는 부족한 경우에 사용합니다. Prompt Guard는 **텍스트**를 PCRE allow/deny로 검사하고, Vision Guard는 `**image_url` 픽셀**을 검사합니다 (예: 칩/SoC 도면 vs 일반 사진).

[AI Proxy](https://developer.konghq.com/plugins/ai-proxy/) 또는 [AI Proxy Advanced](https://developer.konghq.com/plugins/ai-proxy-advanced/)와 함께 쓰는 것을 전제로 합니다. Priority는 `775`로, AI Prompt Guard(`771`)와 AI Proxy보다 먼저 실행됩니다.

## 동작 방식

요청마다 플러그인은 다음을 수행합니다.

1. JSON 채팅 body에서 `messages`의 `image_url`을 수집합니다.
2. 이미지가 없고 `skip_if_no_image`가 `true`이면 요청을 그대로 통과시킵니다.
3. 각 이미지(최대 `max_images`개)를 `classify_prompt`(`deny_prompts` / `allow_prompts`)와 함께 `vision_url`로 보냅니다.
4. 모델 응답에서 `VERDICT: ALLOW` / `VERDICT: DENY`를 파싱합니다 (마지막 매칭 우선).

판정 규칙:

- 이미지 중 하나라도 **DENY**이면 호출자는 `deny_status`(기본 `400`)를 받고 upstream LLM으로 가지 않습니다.
- 분류한 이미지가 모두 **ALLOW**이면 AI Proxy / upstream으로 이어집니다.
- 비전 호출이 실패하고 `fail_open`이 `false`(기본)이면 `500`을 반환합니다.
- 비전 호출이 실패하고 `fail_open`이 `true`이면 요청을 통과시킵니다.

판정이 있을 때 응답 헤더:


| 헤더                        | 값                           |
| ------------------------- | --------------------------- |
| `X-Vision-Guard-Decision` | `ALLOW`, `DENY`, 또는 `ERROR` |
| `X-Vision-Guard-Model`    | 비전 모델 id                    |


## 권장 사항

- 같은 Route에서 **텍스트** 반출·jailbreak 패턴은 AI Prompt Guard, **이미지**는 Vision Guard로 나눕니다.
- `classify_prompt.deny_prompts` / `allow_prompts`는 구체적으로 둡니다. `VERDICT:` suffix는 플러그인이 고정합니다.
- 분류 누락이 비전 endpoint 단기 장애보다 위험하면 `fail_open: false`를 유지합니다.
- 데모에서는 파일명이 아니라 픽셀을 보도록 `data:image/...;base64,...` URL을 권장합니다.

## 설치

1. 플러그인을 로드할 모든 Kong 노드(하이브리드면 Control Plane과 Data Plane)에 배포합니다.

```bash
# 이 저장소 루트에서
luarocks make ai-vision-guard-0.2.0-1.rockspec
```

또는 `kong/plugins/ai-vision-guard/`를 Kong Lua 경로에 복사합니다. 예:

```text
<lua_package_path>/kong/plugins/ai-vision-guard/
```

Docker/Kubernetes에서는 동일 경로로 디렉터리를 마운트하거나 이미지에 포함합니다.

1. Kong 설정에서 플러그인 이름을 활성화합니다.

```bash
# kong.conf
plugins = bundled,ai-vision-guard

# 또는 환경 변수
export KONG_PLUGINS="bundled,ai-vision-guard"
```

1. Kong을 재시작하거나 reload한 뒤 목록에 있는지 확인합니다.

```bash
curl -s http://localhost:8001/plugins/enabled \
  | jq '.enabled_plugins | index("ai-vision-guard")'
```

배포 환경에 맞게 Admin API 주소와 인증 헤더(RBAC 토큰, Konnect PAT 등)를 사용합니다.

1. Admin API, decK, Manager로 Service 또는 Route에 플러그인을 붙입니다. AI Proxy / AI Proxy Advanced와 함께 쓰고, OpenAI 호환 비전 chat-completions endpoint에 대해 최소한 `vision_url`과 `vision_model`을 설정합니다.

### decK로 설정

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

텍스트 allow/deny가 필요하면 같은 Service 또는 Route에 [AI Prompt Guard](https://developer.konghq.com/plugins/ai-prompt-guard/)를 추가로 붙입니다.

## `classify_prompt` 예시

`classify_prompt`는 [AI Semantic Prompt Guard](https://developer.konghq.com/plugins/ai-semantic-prompt-guard/)처럼 `deny_prompts` / `allow_prompts`만 설정합니다. preamble, intro, `VERDICT:` suffix는 플러그인이 고정합니다.

### 1. 반도체 / 칩 IP (플러그인 기본값)

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

### 2. 신분증·얼굴 사진 (개인정보)

```yaml
classify_prompt:
  deny_prompts:
    - government ID, passport, driver's license, or similar identity documents
    - clear close-up face photos suitable for biometric identification
    - credit/debit cards with visible PAN or CVV
  allow_prompts:
    - ordinary scenes, product photos, memes, and documents without identity data
```

decK:

```yaml
config:
  classify_prompt:
    deny_prompts:
      - internal admin consoles with customer records
    allow_prompts:
      - public marketing sites without real data
```

## 설정


| 필드                         | 설명                                    |
| -------------------------- | ------------------------------------- |
| `vision_url`               | 비전 모델용 OpenAI 호환 chat completions URL |
| `vision_model`             | 비전 / 멀티모달 모델 id                       |
| `vision_auth_header_name`  | 인증 헤더 이름 (기본 `Authorization`)         |
| `vision_auth_header_value` | 전체 인증 값, 예: `Bearer <token>`          |
| `classify_prompt`          | `deny_prompts`, `allow_prompts`만 설정 (preamble·intro·VERDICT suffix는 플러그인 고정) |
| `max_images`               | 분류할 `image_url` 최대 개수 (하나라도 DENY면 차단) |
| `skip_if_no_image`         | 이미지 없으면 통과 (기본 `true`)                |
| `fail_open`                | 비전 호출 실패 시 통과 (기본 `false`)            |
| `deny_status`              | DENY 시 HTTP 상태 (기본 `400`)             |
| `max_request_body_size`    | 검사할 body 최대 크기(바이트, 기본 25 MiB)        |
| `tls_verify`               | `vision_url` TLS 검증 (기본 `false`)      |


## 관련

- [AI Prompt Guard](https://developer.konghq.com/plugins/ai-prompt-guard/) — 텍스트 정규식 allow/deny
- [AI Semantic Prompt Guard](https://developer.konghq.com/plugins/ai-semantic-prompt-guard/) — 임베딩 기반 텍스트 가드

[English](README.md)