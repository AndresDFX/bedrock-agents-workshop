#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Pruebas del Agente Autónomo (boto3 → invoke_agent.py).
#
# Uso:
#   bash test.sh              → los 3 escenarios básicos
#   bash test.sh 1|2|3       → un escenario
#   bash test.sh trace [N]   → escenario N con --trace (default N=2)
#   bash test.sh chat        → multi-turno (--chat)
#   bash test.sh confirm     → reembolso ORD-1001 + confirmación humana
#   bash test.sh compare     → mismo prompt: chatbot Haiku vs agente
# ─────────────────────────────────────────────────────────────

if [[ -z "${AGENT_ID:-}" || -z "${ALIAS_ID:-}" ]]; then
  if [[ -f agent.env ]]; then
    # shellcheck disable=SC1091
    source agent.env
  else
    echo "❌ No se encontraron AGENT_ID / ALIAS_ID."
    echo "   Ejecuta primero:  bash deploy.sh && source agent.env"
    exit 1
  fi
fi

export AWS_REGION="${AWS_REGION:-us-east-1}"

PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [[ -z "${PYTHON_BIN}" ]]; then
  echo "❌ No encontré 'python3' ni 'python' en el PATH."
  exit 1
fi

if ! "${PYTHON_BIN}" -c "import boto3" 2>/dev/null; then
  echo "ℹ️  Instalando boto3 para el usuario actual..."
  "${PYTHON_BIN}" -m pip install --quiet --user boto3
fi

prompt_for_scenario() {
  case "${1}" in
    1) echo "¿Cuánto cuesta el monitor y cuántos hay en stock?" ;;
    2) echo "Quiero un reembolso para mi pedido ORD-1001 porque el producto llegó dañado" ;;
    3) echo "Necesito reembolso del pedido ORD-1004" ;;
    *) echo "¿Cuánto cuesta el monitor y cuántos hay en stock?" ;;
  esac
}

SUBCMD="${1:-all}"

if [[ "${SUBCMD}" == "trace" ]]; then
  N="${2:-2}"
  PROMPT="$(prompt_for_scenario "${N}")"
  echo ""
  echo "────────────────────────────────────────────────────────"
  echo "▶ Trace en vivo — escenario ${N}"
  echo "  Prompt: ${PROMPT}"
  echo "────────────────────────────────────────────────────────"
  "${PYTHON_BIN}" invoke_agent.py --trace "${PROMPT}"
  exit 0
fi

if [[ "${SUBCMD}" == "chat" ]]; then
  TRACE_FLAG=()
  if [[ "${2:-}" == "trace" ]]; then
    TRACE_FLAG=(--trace)
  fi
  echo ""
  echo "────────────────────────────────────────────────────────"
  echo "▶ Modo chat multi-turno (Ctrl+D o 'salir' para terminar)"
  echo "   Opcional: bash test.sh chat trace"
  echo "────────────────────────────────────────────────────────"
  "${PYTHON_BIN}" invoke_agent.py --chat "${TRACE_FLAG[@]}"
  exit 0
fi

if [[ "${SUBCMD}" == "confirm" ]]; then
  PROMPT="Quiero un reembolso para mi pedido ORD-1001 porque el producto llegó dañado"
  echo ""
  echo "────────────────────────────────────────────────────────"
  echo "▶ Human-in-the-loop (confirmación antes de procesar_reembolso)"
  echo "  Prompt: ${PROMPT}"
  echo "────────────────────────────────────────────────────────"
  "${PYTHON_BIN}" invoke_agent.py "${PROMPT}"
  exit 0
fi

if [[ "${SUBCMD}" == "compare" ]]; then
  PROMPT="Quiero un reembolso para mi pedido ORD-1001 porque el producto llegó dañado"
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo " A) Chatbot tradicional — solo modelo Haiku (sin herramientas)"
  echo "════════════════════════════════════════════════════════"
  "${PYTHON_BIN}" invoke_chatbot.py "${PROMPT}"
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo " B) Agente Bedrock — Action Groups + Lambda + orquestación"
  echo "    (AUTO_CONFIRM=CONFIRM para completar la demo sin prompts)"
  echo "════════════════════════════════════════════════════════"
  AUTO_CONFIRM=CONFIRM "${PYTHON_BIN}" invoke_agent.py "${PROMPT}"
  exit 0
fi

invoke() {
  local titulo="$1"
  local prompt="$2"
  echo ""
  echo "────────────────────────────────────────────────────────"
  echo "▶ ${titulo}"
  echo "  Prompt: ${prompt}"
  echo "────────────────────────────────────────────────────────"
  AUTO_CONFIRM=CONFIRM "${PYTHON_BIN}" invoke_agent.py "${prompt}"
  echo ""
}

ESCENARIO="${SUBCMD}"

if [[ "${ESCENARIO}" == "all" || "${ESCENARIO}" == "1" ]]; then
  invoke "Escenario 1 — Consulta simple (1 herramienta)" \
    "$(prompt_for_scenario 1)"
fi

if [[ "${ESCENARIO}" == "all" || "${ESCENARIO}" == "2" ]]; then
  invoke "Escenario 2 — Flujo multi-paso autónomo (verifica + reembolsa)" \
    "$(prompt_for_scenario 2)"
fi

if [[ "${ESCENARIO}" == "all" || "${ESCENARIO}" == "3" ]]; then
  invoke "Escenario 3 — Pedido no elegible (más de 30 días)" \
    "$(prompt_for_scenario 3)"
fi

if [[ "${ESCENARIO}" != "all" && "${ESCENARIO}" != "1" && "${ESCENARIO}" != "2" && "${ESCENARIO}" != "3" ]]; then
  echo "❌ Subcomando desconocido: ${ESCENARIO}"
  echo "   Usa: bash test.sh | bash test.sh 1|2|3 | bash test.sh trace [N] | bash test.sh chat | bash test.sh confirm | bash test.sh compare"
  exit 1
fi

echo ""
echo "✅ Pruebas finalizadas."
