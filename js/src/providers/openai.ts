/**
 * OpenAI chat completions over HTTPS with server-sent events. The same code serves
 * `local`: an OpenAI-compatible server (Ollama, LM Studio, vLLM) at a base URL from
 * the settings, with no key. Port of `OpenAIProvider.swift`.
 */
import type { ProviderKind } from '../catalog';
import { messageParts, type ChatEvent, type ChatMessage, type ChatRequest, type StopReason, type Usage } from '../chat';
import { TokenXError } from '../chat';
import { arr, callMaxTokens, callTemperature, num, obj, parseJSONObject, str, type Provider, type ProviderCall, type ProviderStreamParser } from '../provider';
import { httpRequest, SSEParser, type HttpRequest } from '../transport';

export const OPENAI_ENDPOINT = 'https://api.openai.com/v1/chat/completions';

function content(message: ChatMessage): string | unknown[] {
  if (!message.parts) return message.text;
  return messageParts(message).map((p) =>
    p.type === 'text' ? { type: 'text', text: p.text } : { type: 'image_url', image_url: { url: `data:${p.mediaType};base64,${p.data}` } },
  );
}

export class OpenAIProvider implements Provider {
  constructor(readonly kind: ProviderKind = 'openai') {}

  request(chat: ChatRequest, call: ProviderCall): HttpRequest {
    const messages: unknown[] = [];
    if (chat.system) messages.push({ role: 'system', content: chat.system });
    for (const m of chat.messages) messages.push({ role: m.role, content: content(m) });
    const body: Record<string, unknown> = {
      model: call.model.id,
      stream: true,
      stream_options: { include_usage: true },
      messages,
    };
    if (this.kind === 'openai') {
      body.max_completion_tokens = callMaxTokens(call, chat);
    } else {
      body.max_tokens = callMaxTokens(call, chat);
      const t = callTemperature(call, chat);
      if (t !== undefined) body.temperature = t;
    }
    if (chat.jsonSchema) {
      body.response_format = { type: 'json_schema', json_schema: { name: 'reply', schema: chat.jsonSchema } };
    }
    const headers: Record<string, string> = { 'Content-Type': 'application/json', Accept: 'text/event-stream' };
    let url: string;
    if (this.kind === 'local') {
      if (!call.baseURL) throw TokenXError.transport('no local server URL');
      url = `${call.baseURL.replace(/\/+$/, '')}/chat/completions`;
    } else {
      if (!call.key) throw TokenXError.missingKey('openai');
      headers.Authorization = `Bearer ${call.key}`;
      url = OPENAI_ENDPOINT;
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
