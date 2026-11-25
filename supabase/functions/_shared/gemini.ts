import { GoogleGenAI } from 'npm:@google/genai';

const GEMINI_MODEL = 'gemini-3.5-flash-lite';

export async function callGeminiJson<T>(
  prompt: string,
  responseJsonSchema: Record<string, unknown>,
): Promise<T | null> {
  const apiKey = Deno.env.get('GEMINI_API_KEY');
  if (!apiKey) {
    console.warn('GEMINI_API_KEY not configured; falling back to heuristics.');
    return null;
  }

  try {
    const ai = new GoogleGenAI({ vertexai: false, apiKey });
    const response = await ai.models.generateContent({
      model: GEMINI_MODEL,
      contents: prompt,
      config: {
        responseMimeType: 'application/json',
        responseJsonSchema,
      },
    });

    const text = response.text?.trim();
    if (!text) return null;
    return JSON.parse(text) as T;
  } catch (err) {
    console.error('Gemini API call failed:', err);
    return null;
  }
}
