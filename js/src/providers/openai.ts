/**
 * OpenAI chat completions over HTTPS with server-sent events. The same code serves
 * the OpenAI-compatible vendors (DeepSeek, Kimi, Qwen) at their own endpoints, and
 * `local`: an OpenAI-compatible server (Ollama, LM Studio, vLLM) at a base URL from
 * the settings, with no key. Port of `OpenAIProvider.swift`.
 */
import { ProfileInfo, type ProviderKind } from '../catalog';
import { messageParts, type ChatEvent, type ChatMessage, type ChatRequest, type StopReason, type Usage } from '../chat';
import { TokenXError } from '../chat';
import { arr, callMaxTokens, callTemperature, num, obj, parseJSONObject, str, type Provider, type ProviderCall, type ProviderStreamParser } from '../provider';
import { httpRequest, SSEParser, type HttpRequest } from '../transport';

export const OPENAI_ENDPOINT = 'https://api.openai.com/v1/chat/completions';
export const DEEPSEEK_ENDPOINT = 'https://api.deepseek.com/chat/completions';
export const KIMI_ENDPOINT = 'https://api.moonshot.ai/v1/chat/completions';
export const QWEN_ENDPOINT = 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions';

/** The hosted endpoint for a kind; `undefined` for `local`, whose base URL comes from the settings. */
export function openAIEndpoint(kind: ProviderKind): string | undefined {
  switch (kind) {
    case 'openai':
      return OPENAI_ENDPOINT;
    case 'deepseek':
      return DEEPSEEK_ENDPOINT;
    case 'kimi':
      return KIMI_ENDPOINT;
    case 'qwen':
      return QWEN_ENDPOINT;
    default:
      return undefined;
  }
}

/** Whether the vendor enforces a schema (`response_format: json_schema`); the rest get JSON mode and the schema in the prompt. */
export const supportsJSONSchema = (kind: ProviderKind): boolean => kind !== 'deepseek' && kind !== 'qwen';

/** A plain string for text-only messages; text and `image_url` data-URI parts otherwise. */
function content(message: ChatMessage): string | unknown[] {
  if (!message.parts) return message.text;
  return messageParts(message).map((p) =>
    p.type === 'text' ? { type: 'text', text: p.text } : { type: 'image_url', image_url: { url: `data:${p.mediaType};base64,${p.data}` } },
  );
}

export class OpenAIProvider implements Provider {
  constructor(readonly kind: ProviderKind = 'openai') {}

  request(chat: ChatRequest, call: ProviderCall): HttpRequest {
    const kind = this.kind;
    let system = chat.system ?? '';
    const body: Record<string, unknown> = {
      model: call.model.id,
      stream: true,
      stream_options: { include_usage: true },
    };
    // OpenAI and Kimi have retired `max_tokens`; the others still document it.
    body[kind === 'openai' || kind === 'kimi' ? 'max_completion_tokens' : 'max_tokens'] = callMaxTokens(call, chat);
    // OpenAI's current models reject sampling parameters; Kimi fixes the temperature per model.
    const t = callTemperature(call, chat);
    if (kind !== 'openai' && kind !== 'kimi' && t !== undefined) body.temperature = t;
    // The vendors whose models think by default take the profile's effort as a switch: low turns thinking off.
    const effort = ProfileInfo.effort(call.profile);
    if (effort) {
      switch (kind) {
        case 'deepseek':
          body.thinking = effort === 'low' ? { type: 'disabled' } : { type: 'enabled', reasoning_effort: effort };
          break;
        case 'kimi':
          if (call.model.id.startsWith('kimi-k3')) body.reasoning_effort = effort;
          else body.thinking = { type: effort === 'low' ? 'disabled' : 'enabled' };
          break;
        case 'qwen':
          body.enable_thinking = effort !== 'low';
          break;
        default:
          break;
      }
    }
    if (chat.jsonSchema) {
      if (supportsJSONSchema(kind)) {
        body.response_format = { type: 'json_schema', json_schema: { name: 'reply', schema: chat.jsonSchema } };
      } else {
        // JSON mode only: the schema goes in the prompt, which must mention JSON for these APIs to accept the mode.
        body.response_format = { type: 'json_object' };
        system += `${system ? '\n\n' : ''}Reply with a single JSON object that matches this JSON schema: ${JSON.stringify(chat.jsonSchema)}`;
      }
    }
    const messages: unknown[] = [];
    if (system) messages.push({ role: 'system', content: system });
    for (const m of chat.messages) messages.push({ role: m.role, content: content(m) });
    body.messages = messages;
    const headers: Record<string, string> = { 'Content-Type': 'application/json', Accept: 'text/event-stream' };
    let url: string;
    if (kind === 'local') {
      if (!call.baseURL) throw TokenXError.transport('no local server URL');
      url = `${call.baseURL.replace(/\/+$/, '')}/chat/completions`;
    } else {
      if (!call.key) throw TokenXError.missingKey(kind);
      const hosted = openAIEndpoint(kind);
      if (!hosted) throw TokenXError.transport(`no endpoint for ${kind}`);
      headers.Authorization = `Bearer ${call.key}`;
      url = hosted;
    }
    return httpRequest(url, headers, body);
  }

  makeParser(): ProviderStreamParser {
    return new OpenAIParser();
  }
}

class OpenAIParser implements ProviderStreamParser {
  private sse = new SSEParser();
  private usage: Usage = { promptTokens: 0, replyTokens: 0 };
  private stop: StopReason = 'end';
  private finished = false;

  feed(line: string): ChatEvent[] {
    const event = this.sse.feed(line);
    if (!event) return [];
    if (event.data === '[DONE]') {
      this.finished = true;
      return [{ type: 'done', usage: { ...this.usage }, stop: this.stop }];
    }
    const json = parseJSONObject(event.data);
    if (!json) return [];
    const out: ChatEvent[] = [];
    const u = obj(json.usage);
    if (u) {
      this.usage = { promptTokens: num(u.prompt_tokens) ?? this.usage.promptTokens, replyTokens: num(u.completion_tokens) ?? this.usage.replyTokens };
    }
    for (const c of arr(json.choices)) {
      const choice = obj(c);
      const text = str(obj(choice?.delta)?.content);
      if (text) out.push({ type: 'text', text });
      const reason = str(choice?.finish_reason);
      if (reason) this.stop = reason === 'length' ? 'maxTokens' : reason === 'content_filter' ? 'refusal' : 'end';
    }
    return out;
  }

  finish(): ChatEvent[] {
    const out = this.feed('');
    if (this.finished) return out;
    this.finished = true;
    out.push({ type: 'done', usage: { ...this.usage }, stop: this.stop });
    return out;
  }
}
