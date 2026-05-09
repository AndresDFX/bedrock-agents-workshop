#!/usr/bin/env python3
"""
Invocación del Agente de Bedrock usando boto3.

La AWS CLI no expone operaciones de streaming como InvokeAgent; boto3 sí.

Modos:
    python invoke_agent.py "Tu pregunta"
    python invoke_agent.py --trace "Tu pregunta"
    python invoke_agent.py --chat              # multi-turno (misma sesión)
    AUTO_CONFIRM=CONFIRM|DENY                  # sin prompt interactivo (útil para scripts)

Variables de entorno (deploy.sh → agent.env):
    AGENT_ID, ALIAS_ID, AWS_REGION (default us-east-1)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

import boto3
from botocore.exceptions import BotoCoreError, ClientError


def _summarize_orchestration_trace(orch: Dict[str, Any]) -> None:
    """Imprime un subconjunto legible del orchestrationTrace."""
    if not orch:
        return

    if "rationale" in orch:
        r = orch["rationale"]
        text = r.get("text") if isinstance(r, dict) else None
        if not text and isinstance(r, dict):
            text = json.dumps(r, ensure_ascii=False, default=str)[:400]
        elif not text:
            text = str(r)[:400]
        print(f"  · [razonamiento] {text}")

    inv_in = orch.get("invocationInput")
    if isinstance(inv_in, dict):
        kb_in = inv_in.get("knowledgeBaseLookupInput")
        if isinstance(kb_in, dict):
            q = kb_in.get("text", "")
            kb_id = kb_in.get("knowledgeBaseId", "?")
            print(f"  · [KB consulta] id={kb_id} → \"{q}\"")
        agi = (
            inv_in.get("actionGroupInvocationInput")
            or inv_in.get("functionInvocationInput")
            or inv_in.get("apiInvocationInput")
        )
        if isinstance(agi, dict):
            ag = (
                agi.get("actionGroupName")
                or agi.get("actionGroup")
                or "ActionGroup"
            )
            fn = agi.get("function")
            if fn:
                params = agi.get("parameters") or []
                param_str = ", ".join(
                    f'{p.get("name")}={p.get("value")}'
                    for p in params
                    if isinstance(p, dict)
                )
                print(f"  · [invocación] {ag}.{fn}({param_str})")
            elif agi.get("apiPath"):
                print(
                    f"  · [invocación API] {ag} {agi.get('httpMethod', '?')} "
                    f"{agi.get('apiPath')}"
                )

    obs = orch.get("observation")
    if isinstance(obs, dict):
        ago = obs.get("actionGroupInvocationOutput")
        kbo = obs.get("knowledgeBaseLookupOutput")
        if isinstance(ago, dict) and ago.get("text"):
            print(f"  · [observación] {ago['text']}")
        elif isinstance(kbo, dict):
            refs = kbo.get("retrievedReferences") or []
            print(f"  · [KB resultados] {len(refs)} fragmento(s) recuperado(s)")
            for i, ref in enumerate(refs[:5], start=1):
                if not isinstance(ref, dict):
                    continue
                content = ref.get("content") or {}
                text = content.get("text", "") if isinstance(content, dict) else ""
                location = ref.get("location") or {}
                src = ""
                if isinstance(location, dict):
                    s3 = location.get("s3Location")
                    if isinstance(s3, dict):
                        src = s3.get("uri", "")
                snippet = (text[:200] + "…") if len(text) > 200 else text
                # Resaltar el archivo origen (ultimo segmento del URI)
                tag = ""
                if src:
                    tag = f" [src={src.rsplit('/', 1)[-1]}]"
                print(f"      {i}. {snippet}{tag}")
        elif obs.get("finalResponse"):
            fr = obs["finalResponse"]
            if isinstance(fr, dict) and fr.get("text"):
                print(f"  · [respuesta del modelo] {fr['text'][:400]}")
        else:
            body_preview = json.dumps(obs, ensure_ascii=False, default=str)[:400]
            print(f"  · [observación] {body_preview}")

    if "finalResponse" in orch:
        fr = orch["finalResponse"]
        if isinstance(fr, dict) and fr.get("responseText"):
            print(f"  · [respuesta final modelo] {fr['responseText'][:400]}")


def _print_trace_event(trace_payload: Dict[str, Any]) -> None:
    inner = trace_payload.get("trace") if isinstance(trace_payload, dict) else None
    if not isinstance(inner, dict):
        return
    orch = inner.get("orchestrationTrace")
    if orch:
        _summarize_orchestration_trace(orch)
    else:
        snippet = json.dumps(inner, ensure_ascii=False, default=str)[:300]
        print(f"  · [trace] {snippet}")


def _consume_completion_stream(
    response: Dict[str, Any],
    *,
    enable_trace: bool,
    print_chunks: bool,
) -> Tuple[str, Optional[Dict[str, Any]]]:
    """
    Recorre el stream completion.
    Si print_chunks=True, imprime texto del modelo conforme llega.
    Retorna (texto_acumulado, returnControl o None).
    """
    text_parts: List[str] = []
    return_control: Optional[Dict[str, Any]] = None

    stream = response.get("completion")
    if stream is None:
        return "", None

    for event in stream:
        if not isinstance(event, dict):
            continue

        if enable_trace and "trace" in event:
            _print_trace_event(event["trace"])

        if "chunk" in event:
            chunk = event["chunk"]
            if isinstance(chunk, dict) and "bytes" in chunk:
                piece = chunk["bytes"]
                if isinstance(piece, bytes):
                    decoded = piece.decode("utf-8", errors="replace")
                    text_parts.append(decoded)
                    if print_chunks:
                        print(decoded, end="", flush=True)

        if "returnControl" in event:
            return_control = event["returnControl"]

        # Errores en stream
        if "internalServerException" in event:
            raise RuntimeError(event["internalServerException"])
        if "dependencyFailedException" in event:
            raise RuntimeError(event["dependencyFailedException"])
        if "badGatewayException" in event:
            raise RuntimeError(event["badGatewayException"])

    if print_chunks and text_parts:
        print()

    return "".join(text_parts), return_control


def _describe_return_control(rc: Dict[str, Any]) -> str:
    lines = [f"invocationId: {rc.get('invocationId', '?')}"]
    for inp in rc.get("invocationInputs") or []:
        if not isinstance(inp, dict):
            continue
        fin = inp.get("functionInvocationInput")
        if isinstance(fin, dict):
            params = fin.get("parameters") or []
            pstr = ", ".join(
                f'{p.get("name")}={p.get("value")}' for p in params if isinstance(p, dict)
            )
            lines.append(f"  función: {fin.get('actionGroup')}.{fin.get('function')}({pstr})")
        ain = inp.get("apiInvocationInput")
        if isinstance(ain, dict):
            lines.append(f"  API: {ain.get('httpMethod')} {ain.get('apiPath')}")
    return "\n".join(lines)


def _build_confirmation_session_state(
    return_control: Dict[str, Any],
    confirmation_state: str,
) -> Dict[str, Any]:
    """confirmation_state: CONFIRM o DENY.

    NOTA: La muestra oficial de AWS para User Confirmation incluye un
    responseBody con TEXT.body aunque sea vacío. Sin él, la API responde
    con ValidationException ("issue with the response body…").
    """
    inv_id = return_control.get("invocationId")
    if not inv_id:
        raise ValueError("returnControl sin invocationId")

    empty_body = {"TEXT": {"body": ""}}

    results: List[Dict[str, Any]] = []
    for inp in return_control.get("invocationInputs") or []:
        if not isinstance(inp, dict):
            continue
        fin = inp.get("functionInvocationInput")
        if isinstance(fin, dict):
            results.append(
                {
                    "functionResult": {
                        "actionGroup": fin["actionGroup"],
                        "function": fin["function"],
                        "confirmationState": confirmation_state,
                        "responseBody": empty_body,
                    }
                }
            )
            continue
        ain = inp.get("apiInvocationInput")
        if isinstance(ain, dict):
            results.append(
                {
                    "apiResult": {
                        "actionGroup": ain["actionGroup"],
                        "apiPath": ain.get("apiPath", ""),
                        "httpMethod": ain.get("httpMethod", ""),
                        "confirmationState": confirmation_state,
                        "responseBody": empty_body,
                    }
                }
            )

    if not results:
        raise ValueError("No se pudieron construir returnControlInvocationResults")

    return {
        "invocationId": inv_id,
        "returnControlInvocationResults": results,
    }


def _invoke_agent_once(
    client: Any,
    *,
    agent_id: str,
    alias_id: str,
    session_id: str,
    input_text: str,
    session_state: Optional[Dict[str, Any]],
    enable_trace: bool,
    print_chunks: bool,
) -> Tuple[str, Optional[Dict[str, Any]]]:
    kwargs: Dict[str, Any] = dict(
        agentId=agent_id,
        agentAliasId=alias_id,
        sessionId=session_id,
        enableTrace=enable_trace,
    )
    if session_state is not None:
        kwargs["sessionState"] = session_state
    else:
        kwargs["inputText"] = input_text

    response = client.invoke_agent(**kwargs)
    return _consume_completion_stream(
        response, enable_trace=enable_trace, print_chunks=print_chunks
    )


def _confirm_interactively(auto: Optional[str]) -> str:
    if auto in ("CONFIRM", "DENY"):
        return auto
    try:
        ans = input(
            "¿Confirmar la acción propuesta por el agente? [s/N]: "
        ).strip().lower()
    except EOFError:
        return "DENY"
    if ans and ans[0] in ("s", "y"):
        return "CONFIRM"
    return "DENY"


def run_single_turn(
    client: Any,
    *,
    agent_id: str,
    alias_id: str,
    prompt: str,
    enable_trace: bool,
    handle_confirmation: bool,
) -> int:
    session_id = f"sesion-{int(time.time())}-{os.getpid()}"
    auto = os.environ.get("AUTO_CONFIRM")

    text, rc = _invoke_agent_once(
        client,
        agent_id=agent_id,
        alias_id=alias_id,
        session_id=session_id,
        input_text=prompt,
        session_state=None,
        enable_trace=enable_trace,
        print_chunks=False,
    )

    if text.strip():
        if enable_trace:
            print()
            print("── Respuesta ──")
        print(text.strip())

    iterations = 0
    while rc and handle_confirmation and iterations < 8:
        iterations += 1
        print()
        print("── El agente solicita confirmación (human-in-the-loop) ──")
        print(_describe_return_control(rc))

        choice = _confirm_interactively(auto)
        session_state = _build_confirmation_session_state(rc, choice)

        if enable_trace:
            print(f"\n→ Enviando confirmationState={choice} ...\n")
        else:
            print(f"→ confirmationState={choice}")

        text, rc = _invoke_agent_once(
            client,
            agent_id=agent_id,
            alias_id=alias_id,
            session_id=session_id,
            input_text="",
            session_state=session_state,
            enable_trace=enable_trace,
            print_chunks=False,
        )

        if text.strip():
            if enable_trace:
                print()
                print("── Respuesta tras confirmación ──")
            print(text.strip())

    if rc and not handle_confirmation:
        print(
            "\n⚠️  Hay returnControl pendiente; usa el modo interactivo o AUTO_CONFIRM.",
            file=sys.stderr,
        )

    return 0


def run_chat(
    client: Any,
    *,
    agent_id: str,
    alias_id: str,
    enable_trace: bool,
) -> int:
    session_id = f"chat-{int(time.time())}-{os.getpid()}"
    auto = os.environ.get("AUTO_CONFIRM")

    print("Modo chat multi-turno. Escribe 'salir' para terminar.")
    print(f"sessionId={session_id}\n")

    while True:
        try:
            line = input("Tú> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not line or line.lower() in ("salir", "exit", "quit"):
            break

        text, rc = _invoke_agent_once(
            client,
            agent_id=agent_id,
            alias_id=alias_id,
            session_id=session_id,
            input_text=line,
            session_state=None,
            enable_trace=enable_trace,
            print_chunks=False,
        )

        if text.strip():
            if enable_trace:
                print("\n── Respuesta ──")
            print(text.strip())

        iterations = 0
        while rc and iterations < 8:
            iterations += 1
            print("\n── Confirmación requerida ──")
            print(_describe_return_control(rc))
            choice = _confirm_interactively(auto)
            session_state = _build_confirmation_session_state(rc, choice)
            text, rc = _invoke_agent_once(
                client,
                agent_id=agent_id,
                alias_id=alias_id,
                session_id=session_id,
                input_text="",
                session_state=session_state,
                enable_trace=enable_trace,
                print_chunks=False,
            )
            if text.strip():
                print()
                print(text.strip())

        print()

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Invoca un Bedrock Agent (boto3, streaming)."
    )
    parser.add_argument("--trace", action="store_true", help="Mostrar trazas de orquestación")
    parser.add_argument(
        "--chat",
        action="store_true",
        help="Modo interactivo multi-turno (misma sesión)",
    )
    parser.add_argument(
        "--no-confirm-handler",
        action="store_true",
        help="No seguir el flujo returnControl / confirmación humana",
    )
    parser.add_argument(
        "prompt",
        nargs="*",
        help="Texto para el agente (omitir si usas --chat)",
    )

    args = parser.parse_args()

    agent_id = os.environ.get("AGENT_ID")
    alias_id = os.environ.get("ALIAS_ID")
    region = os.environ.get("AWS_REGION", "us-east-1")

    if not agent_id or not alias_id:
        print(
            "❌ Faltan AGENT_ID o ALIAS_ID.\n   Ejecuta: source agent.env",
            file=sys.stderr,
        )
        return 1

    client = boto3.client("bedrock-agent-runtime", region_name=region)

    try:
        if args.chat:
            return run_chat(
                client,
                agent_id=agent_id,
                alias_id=alias_id,
                enable_trace=args.trace,
            )

        prompt = " ".join(args.prompt).strip()
        if not prompt:
            parser.error("Indica un prompt o usa --chat")

        return run_single_turn(
            client,
            agent_id=agent_id,
            alias_id=alias_id,
            prompt=prompt,
            enable_trace=args.trace,
            handle_confirmation=not args.no_confirm_handler,
        )
    except (ClientError, BotoCoreError) as exc:
        print(f"❌ Error de AWS: {exc}", file=sys.stderr)
        return 1
    except RuntimeError as exc:
        print(f"❌ {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
