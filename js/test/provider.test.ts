import { describe, expect, it } from 'vitest';
import {
  AnthropicProvider,
  ANTHROPIC_ENDPOINT,
  anthropicMessages,
  bodyJSON,
  Catalog,
  ChatMessage,
  GeminiProvider,
  LineSplitter,
  OpenAIProvider,
  type ChatRequest,
  type Provider,
  type StopReason,
  type Usage,
} from '../src';
import { Canned } from './fake-transport';

const chat: ChatRequest = { system: 'You are a bush.', messages: [ChatMessage.user('hello'), ChatMessage.assistant('hi'), ChatMessage.user('sing')] };

function collect(provider: Provider, body: string): { text: string; done?: { usage: Usage; stop: StopReason } } {
  const parser = provider.makeParser();
  let text = '';
  let done: { usage: Usage; stop: StopReason } | undefined;
  const splitter = new LineSplitter();
  const lines = splitter.append(new TextEncoder().encode(body));
  const last = splitter.flush();
  if (last !== undefined) lines.push(last);
  const handle = (events: ReturnType<typeof parser.feed>) => {
    for (const e of events) {
      if (e.type === 'text') text += e.text;
      else done = { usage: e.usage, stop: e.stop };
    }
  };
  for (const line of lines) handle(parser.feed(line));
  handle(parser.finish());
  return { text, done };
}

describe('AnthropicProvider', () => {
  const provider = new AnthropicProvider();

  it('builds the request and parses the stream', () => {
    const request = provider.request(chat, { model: Catalog.model('claude-opus-5-5')!, key: 'sk-test', profile: 'character' });
    expect(request.url).toBe(ANTHROPIC_ENDPOINT);
    expect(request.headers['x-api-key']).toBe('sk-test');
    expect(request.headers['anthropic-version']).toBe('2023-06-01');
    expect(request.headers['anthropic-beta']).toBe('server-side-fallback-2026-07-01');
    const body = bodyJSON(request)!;
    expect(body.model).toBe('claude-opus-5-5');
    expect(body.max_tokens).toBe(400);
    expect(body.stream).toBe(true);
    expect(body.system).toBe('You are a bush.');
    expect(body.fallbacks).toBe('default');
    expect((body.output_config as { effort: string }).effort).toBe('low');
    expect(body.temperature, 'sampling parameters are not sent to the 5-generation models').toBeUndefined();
    expect((body.messages as { role: string }[]).map((m) => m.role)).toEqual(['user', 'assistant', 'user']);
    const result = collect(provider, Canned.anthropic);
    expect(result.text).toBe('Ask, and the bush shall sing.');
    expect(result.done?.usage).toEqual({ promptTokens: 25, replyTokens: 9 });
    expect(result.done?.stop).toBe('end');
  });

  it('keeps temperature and sends no effort or fallbacks on Haiku', () => {
    const request = provider.request(chat, { model: Catalog.model('claude-haiku-4-5')!, key: 'k', profile: 'character' });
    const body = bodyJSON(request)!;
    expect(body.temperature).toBe(0.9);
    expect(body.output_config).toBeUndefined();
    expect(body.fallbacks).toBeUndefined();
    expect(request.headers['anthropic-beta']).toBeUndefined();
  });

  it('requires a key', () => {
    expect(() => provider.request(chat, { model: Catalog.model('claude-opus-5-5')!, profile: 'fast' })).toThrow(/no API key/);
  });

  it('merges adjacent roles and starts with user', () => {
    const merged = anthropicMessages([ChatMessage.assistant('a'), ChatMessage.user('b'), ChatMessage.user('c')]);
    expect(merged.map((m) => m.role)).toEqual(['user', 'assistant', 'user']);
    expect(merged[2]!.content).toBe('b\nc');
  });

  it('sends image parts as base64 blocks and a JSON schema as output_config.format', () => {
    const schema = { type: 'object', properties: { ok: { type: 'boolean' } }, required: ['ok'], additionalProperties: false };
    const request = provider.request(
      {
        messages: [ChatMessage.userParts([{ type: 'text', text: 'Photo 1' }, { type: 'image', mediaType: 'image/jpeg', data: 'AAAA' }, { type: 'text', text: 'Compare.' }])],
        jsonSchema: schema,
        maxTokens: 8000,
      },
      { model: Catalog.model('claude-opus-5-5')!, key: 'k', profile: 'vision' },
    );
    const body = bodyJSON(request)!;
    expect(body.max_tokens).toBe(8000);
    const content = (body.messages as { content: unknown[] }[])[0]!.content as { type: string; source?: { media_type: string } }[];
    expect(content.map((c) => c.type)).toEqual(['text', 'image', 'text']);
    expect(content[1]!.source!.media_type).toBe('image/jpeg');
    expect(body.output_config).toEqual({ effort: 'high', format: { type: 'json_schema', schema } });
  });

  it('reports a refusal stop', () => {
    const result = collect(provider, Canned.anthropicRefusal);
    expect(result.done?.stop).toBe('refusal');
    expect(result.text).toBe('');
  });
});

describe('OpenAIProvider', () => {
  it('builds the request and parses the stream', () => {
    const provider = new OpenAIProvider();
    const request = provider.request(chat, { model: Catalog.model('gpt-5-mini')!, key: 'sk-o', profile: 'fast' });
    expect(request.headers.Authorization).toBe('Bearer sk-o');
    const body = bodyJSON(request)!;
    expect(body.max_completion_tokens).toBe(1024);
    expect((body.stream_options as { include_usage: boolean }).include_usage).toBe(true);
    const messages = body.messages as { role: string }[];
    expect(messages[0]!.role).toBe('system');
    expect(messages).toHaveLength(4);
    const result = collect(provider, Canned.openai);
    expect(result.text).toBe('Hello there');
    expect(result.done?.usage).toEqual({ promptTokens: 12, replyTokens: 2 });
  });

  it('serves a local server from its base URL with no key', () => {
    const provider = new OpenAIProvider('local');
    const model = { ...Catalog.local[0]!, id: 'llama3' };
    const request = provider.request(chat, { model, baseURL: 'http://192.168.1.20:11434/v1', profile: 'character' });
    expect(request.url).toBe('http://192.168.1.20:11434/v1/chat/completions');
    expect(request.headers.Authorization).toBeUndefined();
    expect(bodyJSON(request)!.model).toBe('llama3');
    expect(bodyJSON(request)!.temperature).toBe(0.9);
    expect(() => provider.request(chat, { model, profile: 'character' })).toThrow(/no local server URL/);
  });
});

describe('GeminiProvider', () => {
  it('builds the request and parses the stream', () => {
    const provider = new GeminiProvider();
    const request = provider.request(chat, { model: Catalog.model('gemini-2.5-flash')!, key: 'g', profile: 'assistant' });
    expect(request.url.endsWith('gemini-2.5-flash:streamGenerateContent?alt=sse')).toBe(true);
    expect(request.headers['x-goog-api-key']).toBe('g');
    const body = bodyJSON(request)!;
    expect((body.contents as { role: string }[]).map((c) => c.role)).toEqual(['user', 'model', 'user']);
    expect(body.systemInstruction).toBeDefined();
    const result = collect(provider, Canned.gemini);
    expect(result.text).toBe('Woof.');
    expect(result.done?.usage).toEqual({ promptTokens: 7, replyTokens: 2 });
    expect(result.done?.stop).toBe('end');
  });
});

describe('Catalog', () => {
  it('picks the nearest tier and honours vision', () => {
    expect(Catalog.modelFor('character', 'anthropic').id).toBe('claude-opus-5-5');
    expect(Catalog.modelFor('fast', 'openai').id).toBe('gpt-5-nano');
    expect(Catalog.modelFor('vision', 'local').id, 'local has no vision model; falls back to the only one').toBe('local');
  });
});
