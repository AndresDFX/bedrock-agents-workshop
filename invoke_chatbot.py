#!/usr/bin/env python3
"""
Invoca Claude Sonnet 4.5 directamente por Bedrock (invoke_model), sin Action Groups.

Sirve para contrastar en la charla: el modelo solo genera texto y no puede ejecutar
verificar_pedido / procesar_reembolso.

Variables opcionales:
    BEDROCK_MODEL_ID   (default: mismo inference profile que el agente en template.yaml)
    AWS_REGION         (default: us-east-1)

Uso:
    python invoke_chatbot.py "Tu mensaje"
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import boto3
from botocore.exceptions import BotoCoreError, ClientError

DEFAULT_MODEL = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"

SYSTEM_PROMPT = """Eres un asistente de soporte de TechStore, tienda de electrónica en línea.

IMPORTANTE: NO tienes herramientas, APIs ni bases de datos: solo puedes responder en texto.
No puedes consultar pedidos reales ni procesar reembolsos. Si el usuario pide acciones concretas,
explica amablemente esa limitación y sugiere que contacte soporte humano o use el canal oficial.

Responde SIEMPRE en español, de forma clara y cordial."""


def invoke_chatbot(prompt: str, *, region: str, model_id: str) -> str:
    client = boto3.client("bedrock-runtime", region_name=region)
    body = json.dumps(
        {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 2048,
            "temperature": 0.3,
            "system": SYSTEM_PROMPT,
            "messages": [
                {
                    "role": "user",
                    "content": [{"type": "text", "text": prompt}],
                }
            ],
        }
    )
    resp = client.invoke_model(modelId=model_id, body=body)
    payload = json.loads(resp["body"].read())
    parts = payload.get("content") or []
    texts = []
    for block in parts:
        if isinstance(block, dict) and block.get("type") == "text":
            texts.append(block.get("text", ""))
    return "\n".join(texts).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Chatbot Sonnet 4.5 sin herramientas (contraste).")
    parser.add_argument("prompt", nargs="+", help="Mensaje del usuario")
    args = parser.parse_args()

    prompt = " ".join(args.prompt).strip()
    region = os.environ.get("AWS_REGION", "us-east-1")
    model_id = os.environ.get("BEDROCK_MODEL_ID", DEFAULT_MODEL)

    try:
        text = invoke_chatbot(prompt, region=region, model_id=model_id)
        print(text if text else "(sin respuesta)")
        return 0
    except (ClientError, BotoCoreError) as exc:
        print(f"❌ Error de AWS: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
