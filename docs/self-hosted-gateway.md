# 自建 AI 网关（10 分钟）

U盘 上所有 AI 引擎（Claude Code / Codex / OpenClaw / Pi）都只要求一个 **Anthropic 或 OpenAI 兼容端点**。官方托管（tokeneff.com，免费周额度）只是省事选项；本页教你自己搭一个。

## 1. LiteLLM 一键起

```bash
pip install 'litellm[proxy]'
export LITELLM_MASTER_KEY=sk-换成你自己的
litellm --model openai/gpt-4o-mini --port 4000   # 或 glm/qwen 等
# Anthropic 兼容端点: http://127.0.0.1:4000
```

云厂商网关（如 bigmodel.cn 的 GLM、DeepSeek）也直接可用——把 base_url 换成厂商地址即可。

## 2. U盘 侧接线

**Live 维修系统 / AI-Workstation（Claude Code）：**

```bash
export ANTHROPIC_BASE_URL=http://你的网关:4000
export ANTHROPIC_AUTH_TOKEN=sk-你的key
```

写进 U盘 数据分区 `config/auth_token` 与 `config/env.local` 后开机即用。

**Codex CLI（`config/codex/config.toml`）：**

```toml
model = "glm-5.2"
[model_providers.mine]
name = "Mine"
base_url = "http://你的网关:4000/v1"
env_key = "MY_API_KEY"
wire_api = "responses"    # 网关不支持 /v1/responses 时改 "chat"
```

**OpenClaw（`config/openclaw/openclaw.json`）：**

```json5
{
  models: { providers: { mine: {
    baseUrl: "http://你的网关:4000",
    apiKey: "MY_API_KEY",
    api: "anthropic-messages",
    models: [ { id: "glm-5.2", name: "GLM 5.2", reasoning: false, input: ["text"],
                cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                contextWindow: 128000, maxTokens: 8192 } ],
  } } },
  agents: { defaults: { model: "mine/glm-5.2" } },
}
```

**Pi（`config/pi/agent/models.json`）：**

```json
{ "providers": { "mine": {
    "baseUrl": "http://你的网关:4000/v1",
    "api": "openai-completions",
    "apiKey": "MY_API_KEY",
    "models": [ { "id": "glm-5.2" } ]
} } }
```

## 3. 校验

```bash
curl -s $ANTHROPIC_BASE_URL/v1/messages -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
  -H content-type:application/json -d '{"model":"glm-5.2","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}'
```

返回 200 且带 `content` 即通。HTTP 4xx 也说明链路可达（鉴权/参数问题另查）。
