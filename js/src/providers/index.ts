import type { ProviderKind } from '../catalog';
import type { Provider } from '../provider';
import { AnthropicProvider } from './anthropic';
import { GeminiProvider } from './gemini';
import { OpenAIProvider } from './openai';

export { AnthropicProvider, ANTHROPIC_ENDPOINT, ANTHROPIC_VERSION, anthropicMessages } from './anthropic';
export { OpenAIProvider, OPENAI_ENDPOINT, DEEPSEEK_ENDPOINT, KIMI_ENDPOINT, QWEN_ENDPOINT, GROK_ENDPOINT, MISTRAL_ENDPOINT, COHERE_ENDPOINT, OPENROUTER_ENDPOINT, openAIDialect, type Dialect, type Structured } from './openai';
export { GeminiProvider, GEMINI_BASE } from './gemini';

export const Providers = {
  for(kind: ProviderKind): Provider {
    switch (kind) {
      case 'anthropic':
        return new AnthropicProvider();
      case 'gemini':
        return new GeminiProvider();
      default:
        return new OpenAIProvider(kind);
    }
  },
};
