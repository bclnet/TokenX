import type { ProviderKind } from '../catalog';
import type { Provider } from '../provider';
import { AnthropicProvider } from './anthropic';
import { GeminiProvider } from './gemini';
import { OpenAIProvider } from './openai';

export { AnthropicProvider, ANTHROPIC_ENDPOINT, ANTHROPIC_VERSION, anthropicMessages } from './anthropic';
export { OpenAIProvider, OPENAI_ENDPOINT, DEEPSEEK_ENDPOINT, KIMI_ENDPOINT, QWEN_ENDPOINT } from './openai';
export { GeminiProvider, GEMINI_BASE } from './gemini';

export const Providers = {
  for(kind: ProviderKind): Provider {
    switch (kind) {
      case 'anthropic':
        return new AnthropicProvider();
      case 'openai':
      case 'deepseek':
      case 'kimi':
      case 'qwen':
      case 'local':
        return new OpenAIProvider(kind);
      case 'gemini':
        return new GeminiProvider();
    }
  },
};
