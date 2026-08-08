// tide-vision — the AI brain for the Tide Glasses app.
//
// The phone sends a spoken question and, when the wearer asked for one, a JPEG
// thumbnail captured off the glasses over Bluetooth. The reply streams back as
// SSE so the phone can start speaking the first sentence while the model is
// still writing the rest.
//
// The camera is driven by the wearer saying "take a photo", decided on the
// phone before the request is sent. An earlier version let the model ask to
// see by replying with a marker; it cost an extra round trip on exactly the
// slowest questions and misjudged real phrasings, so it is gone.
//
// `memory` is the wearer's own block of facts, carried in on every request and
// written ONLY by the phone. Nothing this function returns is ever fed back
// into it — the model reads that block and can never change it.
//
// Deployed to the Dharma Daily project (uteervxxzmmhbzymouin), which holds
// OPENROUTER_API_KEY. It previously ran on Kernel (zwxmmkiwvhsjdztenwfy),
// which belongs to another app; moved 2026-08-08. Deploy with the Supabase
// MCP or:
//   supabase functions deploy tide-vision --no-verify-jwt
//
// verify_jwt MUST stay false: the app authenticates with the x-tide-key header
// below and sends no Authorization header at all.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const MODEL = "openai/gpt-5.6-luna";

const OPENROUTER_API_KEY = Deno.env.get("OPENROUTER_API_KEY");

// SHA-256 of the device key. The key itself lives only in the iOS Keychain —
// it is never in this file, the repo, or the app binary. Rotate by generating
// a new key, replacing this hash, and redeploying.
const DEVICE_KEY_SHA256 =
  "7f5f5bc121813661027fd624a456652faf69965d7fb11c7d4b3e5ca806af5518";

// Cost guards. This endpoint is reachable without a Supabase JWT, so a leaked
// device key must not be able to run up a bill.
const MAX_QUESTION_CHARS = 2000;
const MAX_IMAGE_BYTES = 400_000; // decoded
// The app caps memory at 1000 characters; leave headroom without letting a
// modified client push an unbounded block through on every request.
const MAX_MEMORY_CHARS = 1500;
// Twenty turns, not eight. A chat is meant to run for days now, and eight was
// four exchanges — it forgot almost immediately. The phone also applies a
// character budget before sending, so this is the ceiling, not the norm.
const MAX_HISTORY_TURNS = 20;
const MAX_TOKENS = 300;

// Spoken answers, not written ones. The phone reads this straight out loud, so
// markdown, lists, and headers all come out as noise.
const SYSTEM_PROMPT = `You are Tide, a voice assistant living in a pair of smart glasses.

The person is wearing the glasses and talking to you out loud. Your reply is spoken back to them, so:
- Answer in one or two short sentences. Three at the very most.
- Plain spoken language. No markdown, no bullet points, no headers, no emoji.
- No preamble. Never start with "I see" or "This appears to be" — just say the thing.
- If an image is attached it is a low-resolution thumbnail from the glasses camera, taken from the wearer's point of view. Say what it is directly. If it is genuinely too blurry to tell, say so in one sentence and suggest they get closer.
- If a question clearly refers to something in front of the wearer but no image is attached, do not guess — say in one short sentence that you need to see it, and that they can add "take a photo" to their question.
- If you are not sure, say so briefly rather than guessing confidently.`;

// How the model is told to treat the memory block. Two things matter here: it
// should use the facts without being asked, and it must never claim to have
// saved something. Saving happens on the phone, only when the wearer says
// "update memory" — a model that says "I'll remember that" after any other
// phrasing has made a promise nothing kept.
const MEMORY_RULES =
  `You cannot write to this memory. It is saved on the wearer's phone, and only when they say "update memory" followed by the fact.
- Use what you know above whenever it is relevant, without mentioning that you are using it and without being asked.
- If the wearer just asked you to save something, confirm it in a few words, like "Got it." Do not repeat the whole fact back.
- If they ask you to remember something WITHOUT saying "update memory", never say you will remember it. Tell them in one short sentence to say "update memory" and then the fact.`;

function buildSystemPrompt(memory?: string): string {
  if (!memory) return SYSTEM_PROMPT;
  return `${SYSTEM_PROMPT}

What you know about the wearer. They wrote this themselves, so treat it as true:
${memory}

${MEMORY_RULES}`;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-tide-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// Compare without leaking where the strings diverge.
function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

interface Turn {
  role: "user" | "assistant";
  content: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  if (!OPENROUTER_API_KEY) {
    return json({ error: "Server is not configured. Missing OPENROUTER_API_KEY." }, 500);
  }

  const presentedKey = req.headers.get("x-tide-key") ?? "";
  if (!presentedKey || !constantTimeEquals(await sha256Hex(presentedKey), DEVICE_KEY_SHA256)) {
    return json({ error: "Unauthorized." }, 401);
  }

  let question: string;
  let imageBase64: string | undefined;
  let history: Turn[] | undefined;
  let memory: string | undefined;
  try {
    ({ question, imageBase64, history, memory } = await req.json());
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  if (typeof question !== "string" || question.trim().length === 0) {
    return json({ error: "`question` must be a non-empty string" }, 400);
  }
  if (question.length > MAX_QUESTION_CHARS) {
    return json({ error: `Question too long (max ${MAX_QUESTION_CHARS} chars).` }, 400);
  }
  if (imageBase64 !== undefined) {
    if (typeof imageBase64 !== "string") {
      return json({ error: "`imageBase64` must be a string" }, 400);
    }
    // base64 inflates by 4/3; check the decoded size without decoding.
    if ((imageBase64.length * 3) / 4 > MAX_IMAGE_BYTES) {
      return json({ error: `Image too large (max ${MAX_IMAGE_BYTES} bytes).` }, 400);
    }
  }
  if (memory !== undefined) {
    if (typeof memory !== "string") {
      return json({ error: "`memory` must be a string" }, 400);
    }
    if (memory.length > MAX_MEMORY_CHARS) {
      return json({ error: `Memory too long (max ${MAX_MEMORY_CHARS} chars).` }, 400);
    }
  }

  const trimmedMemory = typeof memory === "string" ? memory.trim() : "";

  const priorTurns = Array.isArray(history)
    ? history
        .filter((t) => t && (t.role === "user" || t.role === "assistant") && typeof t.content === "string")
        .slice(-MAX_HISTORY_TURNS)
        .map((t) => ({ role: t.role, content: t.content.slice(0, MAX_QUESTION_CHARS) }))
    : [];

  const userContent = imageBase64
    ? [
        { type: "text", text: question },
        { type: "image_url", image_url: { url: `data:image/jpeg;base64,${imageBase64}` } },
      ]
    : question;

  const orRes = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENROUTER_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      stream: true,
      provider: {
        // The whole point of this app is that the wearer's photos stay theirs.
        // Only route to providers that do not retain or train on the request.
        data_collection: "deny",
        sort: "throughput",
      },
      messages: [
        { role: "system", content: buildSystemPrompt(trimmedMemory || undefined) },
        ...priorTurns,
        { role: "user", content: userContent },
      ],
    }),
  });

  if (!orRes.ok || !orRes.body) {
    const errText = await orRes.text();
    return json({ error: `OpenRouter error: ${errText}` }, orRes.status);
  }

  return new Response(orRes.body, {
    headers: {
      ...corsHeaders,
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    },
  });
});
