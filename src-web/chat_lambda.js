/**
 * HTTP API (API Gateway) + Lambda proxy (payload format 2.0).
 *
 * Integración tipo AWS_PROXY en modo BUFFERED: acumula el stream de Bedrock
 * en Lambda y devuelve text/plain. Evita el formato de streaming propio de
 * Function URLs y el error 403 de invocación pública en algunas cuentas.
 *
 * POST JSON: { "prompt": "...", "mode": "chatbot" | "agent" }
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

function plainHeaders() {
  return {
    "content-type": "text/plain; charset=utf-8",
  };
}

async function collectHaikuText(prompt) {
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
  const parts = [];
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
      if (t) parts.push(t);
    }
  }
  return parts.join("");
}

async function collectAgentText(prompt) {
  const agentId = process.env.AGENT_ID;
  const aliasId = process.env.ALIAS_ID;
  if (!agentId || !aliasId) {
    return "Error: faltan variables de entorno AGENT_ID o ALIAS_ID.\n";
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
    return "(sin stream completion)\n";
  }

  const parts = [];
  for await (const event of completion) {
    if (event.chunk?.bytes) {
      const text = Buffer.from(event.chunk.bytes).toString("utf8");
      if (text) parts.push(text);
    }
    if (event.returnControl) {
      parts.push(
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
  return parts.join("");
}

exports.handler = async (event) => {
  let bodyRaw = event.body;
  if (event.isBase64Encoded && bodyRaw) {
    bodyRaw = Buffer.from(bodyRaw, "base64").toString("utf8");
  }

  let payload = {};
  try {
    payload = bodyRaw ? JSON.parse(bodyRaw) : {};
  } catch {
    return {
      statusCode: 400,
      headers: plainHeaders(),
      body: "Error: body JSON inválido.\n",
    };
  }

  const prompt = String(payload.prompt || "").trim();
  const mode = String(payload.mode || "chatbot").toLowerCase();

  if (!prompt) {
    return {
      statusCode: 400,
      headers: plainHeaders(),
      body: "Error: falta el campo prompt.\n",
    };
  }

  try {
    let text;
    if (mode === "chatbot") {
      text = await collectHaikuText(prompt);
    } else if (mode === "agent") {
      text = await collectAgentText(prompt);
    } else {
      return {
        statusCode: 400,
        headers: plainHeaders(),
        body: 'Error: mode debe ser "chatbot" o "agent".\n',
      };
    }
    return {
      statusCode: 200,
      headers: plainHeaders(),
      body: text ?? "",
    };
  } catch (err) {
    const msg = err && err.message ? err.message : String(err);
    return {
      statusCode: 500,
      headers: plainHeaders(),
      body: `\n❌ Error: ${msg}\n`,
    };
  }
};
