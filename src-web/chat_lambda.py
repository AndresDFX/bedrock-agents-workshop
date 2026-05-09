#!/usr/bin/env python3
"""
Lógica equivalente (Haiku directo / agente Bedrock) en Python con boto3.

IMPORTANTE — Despliegue en Lambda:
    AWS Lambda solo soporta RESPONSE_STREAM en runtimes **Node.js** gestionados.
    La función que publica la Function URL es ``chat_lambda.js`` (empaquetada en
    ``chat_lambda.zip``). Este archivo sirve como referencia / pruebas locales:

        python chat_lambda.py chatbot "¿Qué es TechCoins?"
        python chat_lambda.py agent "ORD-1001 reembolso"
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import uuid

import boto3
from botocore.exceptions import BotoCoreError, ClientError

# Mismo texto que invoke_chatbot.py y chat_lambda.js
SYSTEM_PROMPT = """Eres un asistente de soporte de TechStore, tienda de electrónica en línea.

IMPORTANTE: NO tienes herramientas, APIs ni bases de datos: solo puedes responder en texto.
No puedes consultar pedidos reales ni procesar reembolsos. Si el usuario pide acciones concretas,
explica amablemente esa limitación y sugiere que contacte soporte humano o use el canal oficial.

Responde SIEMPRE en español, de forma clara y cordial."""

DEFAULT_MODEL = os.environ.get(
    "BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0"
)


def stream_chatbot(prompt: str, *, region: str, model_id: str) -> None:
    client = boto3.client("bedrock-runtime", region_name=region)
    body = json.dumps(
        {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 2048,
            "temperature": 0.3,
            "system": SYSTEM_PROMPT,
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": prompt}]}
            ],
        }
    )
    resp = client.invoke_model_with_response_stream(
        modelId=model_id, body=body, accept="application/json"
    )
    for event in resp.get("body") or []:
        chunk = event.get("chunk")
        if not chunk or "bytes" not in chunk:
            continue
        try:
            payload = json.loads(chunk["bytes"])
        except (json.JSONDecodeError, TypeError):
            continue
        if payload.get("type") == "content_block_delta":
            delta = payload.get("delta") or {}
            if delta.get("type") == "text_delta":
                text = delta.get("text") or ""
                if text:
                    print(text, end="", flush=True)


def stream_agent(prompt: str, *, region: str, agent_id: str, alias_id: str) -> None:
    client = boto3.client("bedrock-agent-runtime", region_name=region)
    session_id = f"cli-{uuid.uuid4()}"
    response = client.invoke_agent(
        agentId=agent_id,
        agentAliasId=alias_id,
        sessionId=session_id,
        inputText=prompt,
        enableTrace=False,
    )
    stream = response.get("completion")
    if stream is None:
        print("(sin completion)", file=sys.stderr)
        return
    for event in stream:
        if not isinstance(event, dict):
            continue
        if "chunk" in event:
            ch = event["chunk"]
            if isinstance(ch, dict) and "bytes" in ch:
                piece = ch["bytes"]
                if isinstance(piece, bytes):
                    print(piece.decode("utf-8", errors="replace"), end="", flush=True)
        if "returnControl" in event:
            print(
                "\n\n[Pausa] returnControl / RequireConfirmation "
                "(demo web simplificada sin CONFIRM).\n",
                end="",
                flush=True,
            )
            break


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prueba local de streaming (la Lambda usa chat_lambda.js)."
    )
    parser.add_argument("mode", choices=("chatbot", "agent"))
    parser.add_argument("prompt", nargs="+")
    args = parser.parse_args()

    prompt = " ".join(args.prompt).strip()
    region = os.environ.get("AWS_REGION", "us-east-1")

    try:
        if args.mode == "chatbot":
            stream_chatbot(prompt, region=region, model_id=DEFAULT_MODEL)
        else:
            agent_id = os.environ.get("AGENT_ID")
            alias_id = os.environ.get("ALIAS_ID")
            if not agent_id or not alias_id:
                print(
                    "❌ Para agent necesitas AGENT_ID y ALIAS_ID (source agent.env)",
                    file=sys.stderr,
                )
                return 1
            stream_agent(prompt, region=region, agent_id=agent_id, alias_id=alias_id)
        print()
        return 0
    except (ClientError, BotoCoreError) as exc:
        print(f"\n❌ Error AWS: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
