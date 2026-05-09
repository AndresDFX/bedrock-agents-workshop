/**
 * Lambda Function URL + RESPONSE_STREAM (solo runtime Node.js gestionado).
 *
 * Expone POST JSON: { "prompt": "...", "mode": "chatbot" | "agent" }
 * - chatbot: invoke_model_with_response_stream (mismo system prompt que invoke_chatbot.py)
 * - agent: invoke_agent streaming (enableTrace false). Si aparece returnControl,
 *   se informa en texto (demo simplificada sin confirmación desde el navegador).
 */
"use strict";

const { BedrockRuntimeClient, InvokeModelWithResponseStreamCommand } = require("@aws-sdk/client-bedrock-runtime");
const {
  BedrockAgentRuntimeClient,
  InvokeAgentCommand,
} = require("@aws-sdk/client-bedrock-agent-runtime");
const crypto = require("crypto");

const SYSTEM_PROMPT = `Eres un asistente de soporte de TechStore, tienda de electrónica en línea.

IMPORTANTE: NO tienes herramientas, APIs ni bases de datos: solo puedes responder en texto.
No puedes consultar pedidos reales ni procesar reembolsos. Si el usuario pide acciones concretas,
explica amablemente esa limitación y sugiere que contacte soporte humano o use el canal oficial.

Responde SIEMPRE en español, de forma clara y cordial.`;

function defaultModelId() {
  return process.env.BEDROCK_MODEL_ID || "us.anthropic.claude-haiku-4-5-20251001-v1:0";
}

function region() {
  return process.env.AWS_REGION || "us-east-1";
}

async function streamHaiku(prompt, responseStream) {
  const client = new BedrockRuntimeClient({ region: region() });
  const body = JSON.stringify({
    anthropic_version: "bedrock-2023-05-31",
    max_tokens: 2048,
    temperature: 0.3,
    system: SYSTEM_PROMPT,
    messages: [
      {
        role: "user",
        content: [{ type: "text", text: prompt }],
      },
    ],
  });

  const cmd = new InvokeModelWithResponseStreamCommand({
    modelId: defaultModelId(),
    body,
    contentType: "application/json",
    accept: "application/json",
  });

  const resp = await client.send(cmd);
  for await (const part of resp.body) {
    if (part.internalServerException) {
      throw new Error(JSON.stringify(part.internalServerException));
    }
    if (part.modelStreamErrorException) {
      throw new Error(JSON.stringify(part.modelStreamErrorException));
    }
    if (!part.chunk?.bytes) continue;
    let payload;
    try {
      payload = JSON.parse(Buffer.from(part.chunk.bytes).toString("utf8"));
    } catch {
      continue;
    }
    if (payload.type === "content_block_delta" && payload.delta?.type === "text_delta") {
      const t = payload.delta.text || "";
      if (t) responseStream.write(t);
    }
  }
}

async function streamAgent(prompt, responseStream) {
  const agentId = process.env.AGENT_ID;
  const aliasId = process.env.ALIAS_ID;
  if (!agentId || !aliasId) {
    responseStream.write("Error: faltan variables de entorno AGENT_ID o ALIAS_ID.\n");
    return;
  }

  const client = new BedrockAgentRuntimeClient({ region: region() });
  const sessionId = `web-${crypto.randomUUID()}`;

  const cmd = new InvokeAgentCommand({
    agentId,
    agentAliasId: aliasId,
    sessionId,
    inputText: prompt,
    enableTrace: false,
  });

  const resp = await client.send(cmd);
  const completion = resp.completion;
  if (!completion) {
    responseStream.write("(sin stream completion)\n");
    return;
  }

  for await (const event of completion) {
    if (event.chunk?.bytes) {
      const text = Buffer.from(event.chunk.bytes).toString("utf8");
      if (text) responseStream.write(text);
    }
    if (event.returnControl) {
      responseStream.write(
        "\n\n[Pausa] El agente solicitaría confirmación humana en este punto (RequireConfirmation). Demo web simplificada: no se envía CONFIRM desde el navegador.\n"
      );
      break;
    }
    if (event.internalServerException) {
      throw new Error(JSON.stringify(event.internalServerException));
    }
    if (event.dependencyFailedException) {
      throw new Error(JSON.stringify(event.dependencyFailedException));
    }
    if (event.badGatewayException) {
      throw new Error(JSON.stringify(event.badGatewayException));
    }
  }
}

async function handle(event, responseStream) {
  const http = event.requestContext?.http || {};
  const method = http.method || "POST";

  if (method === "OPTIONS") {
    const meta = {
      statusCode: 204,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "content-type",
      },
    };
    responseStream = awslambda.HttpResponseStream.from(responseStream, meta);
    responseStream.end();
    await responseStream.finished?.();
    return;
  }

  const meta = {
    statusCode: 200,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Access-Control-Allow-Origin": "*",
    },
  };
  responseStream = awslambda.HttpResponseStream.from(responseStream, meta);

  let bodyRaw = event.body;
  if (event.isBase64Encoded && bodyRaw) {
    bodyRaw = Buffer.from(bodyRaw, "base64").toString("utf8");
  }

  let payload = {};
  try {
    payload = bodyRaw ? JSON.parse(bodyRaw) : {};
  } catch {
    responseStream.write("Error: body JSON inválido.\n");
    responseStream.end();
    await responseStream.finished?.();
    return;
  }

  const prompt = String(payload.prompt || "").trim();
  const mode = String(payload.mode || "chatbot").toLowerCase();

  if (!prompt) {
    responseStream.write("Error: falta el campo prompt.\n");
    responseStream.end();
    await responseStream.finished?.();
    return;
  }

  try {
    if (mode === "chatbot") {
      await streamHaiku(prompt, responseStream);
    } else if (mode === "agent") {
      await streamAgent(prompt, responseStream);
    } else {
      responseStream.write('Error: mode debe ser "chatbot" o "agent".\n');
    }
  } catch (err) {
    const msg = err && err.message ? err.message : String(err);
    responseStream.write(`\n❌ Error: ${msg}\n`);
  }

  responseStream.end();
  await responseStream.finished?.();
}

exports.handler = awslambda.streamifyResponse(async (event, responseStream, _context) => {
  await handle(event, responseStream);
});
