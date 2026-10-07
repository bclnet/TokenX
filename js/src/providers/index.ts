import type { ProviderKind } from '../catalog';
import type { Provider } from '../provider';
import { AnthropicProvider } from './anthropic';
import { GeminiProvider } from './gemini';
import { OpenAIProvider } from './openai';

export { AnthropicProvider, ANTHROPIC_ENDPOINT, ANTHROPIC_VERSION, anthropicMessages } from './anthropic';
export { OpenAIProvider, OPENAI_ENDPOINT } from './openai';
export { GeminiProvider, GEMINI_BASE } from './gemini';

export const Providers = {
  for(kind: ProviderKind): Provider {
    switch (kind) {
      case 'anthropic':
        return new AnthropicProvider();
      case 'openai':
        return new OpenAIProvider('openai');
      case 'local':
        return new OpenAIProvider('local');
      case 'gemini':
        return new GeminiProvider();
    }
  },
};
