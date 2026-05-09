#!/usr/bin/env python3
"""
Invocación del Agente de Bedrock usando boto3.

CloudShell trae boto3 y AWS CLI v2, pero la CLI no expone el subcomando
streaming `bedrock-agent-runtime invoke-agent`. Por eso usamos boto3
directamente, igual que el panel "Test" de la consola de Bedrock.

Uso:
    python invoke_agent.py "Tu pregunta para el agente"

Variables de entorno requeridas (las exporta deploy.sh -> agent.env):
    AGENT_ID    ID del agente
    ALIAS_ID    ID del alias
    AWS_REGION  Región (por defecto us-east-1)
"""
import os
import sys
import time
import boto3
from botocore.exceptions import ClientError, BotoCoreError


def main() -> int:
    if len(sys.argv) < 2:
        print("Uso: python invoke_agent.py \"Tu pregunta para el agente\"", file=sys.stderr)
        return 2

    prompt = sys.argv[1]
    agent_id = os.environ.get("AGENT_ID")
    alias_id = os.environ.get("ALIAS_ID")
    region = os.environ.get("AWS_REGION", "us-east-1")

    if not agent_id or not alias_id:
        print(
            "❌ Faltan AGENT_ID o ALIAS_ID en el entorno.\n"
            "   Ejecuta:  source agent.env",
            file=sys.stderr,
        )
        return 1

    session_id = f"sesion-{int(time.time())}-{os.getpid()}"
    client = boto3.client("bedrock-agent-runtime", region_name=region)

    try:
        response = client.invoke_agent(
            agentId=agent_id,
            agentAliasId=alias_id,
            sessionId=session_id,
            inputText=prompt,
        )
    except (ClientError, BotoCoreError) as exc:
        print(f"❌ Error invocando al agente: {exc}", file=sys.stderr)
        return 1

    completion_text = ""
    for event in response.get("completion", []):
        chunk = event.get("chunk")
        if chunk and "bytes" in chunk:
            completion_text += chunk["bytes"].decode("utf-8")

    print(completion_text.strip() if completion_text else "(sin respuesta)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
