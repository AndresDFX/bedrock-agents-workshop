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
#   bash test.sh rag         → 4 prompts que forzarán uso de la Knowledge Base
#   bash test.sh rag 1..4    → uno solo de los escenarios RAG
#   bash test.sh rag trace [N]  → un escenario RAG con --trace
#   bash test.sh rag-vs-chatbot → contraste KB del agente vs chatbot sin RAG
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
  echo " A) Chatbot tradicional — solo modelo Sonnet 4.5 (sin herramientas)"
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

# ─────────────────────────────────────────────────────────────
# Escenarios RAG (Knowledge Base)
# Mezcla 4 prompts: 3 que SÍ están en la KB y 1 que NO debería estar
# (sirve para mostrar que el agente reconoce sus límites en lugar de
# inventar).
# ─────────────────────────────────────────────────────────────
prompt_for_rag() {
  case "${1}" in
    1) echo "¿Cuál es la política de devoluciones de TechStore? ¿Qué pasa si el producto fue abierto?" ;;
    2) echo "¿Cómo funciona el programa TechCoins? ¿Cuántos puntos gano por cada \$10.000 que compro?" ;;
    3) echo "¿Qué garantía tienen los monitores y qué cubre exactamente?" ;;
    4) echo "¿Tienen sucursal en Lima, Perú? ¿En qué dirección queda?" ;;
    *) echo "¿Cuál es la política de devoluciones de TechStore?" ;;
  esac
}

if [[ "${SUBCMD}" == "rag" ]]; then
  SUB2="${2:-all}"
  if [[ "${SUB2}" == "trace" ]]; then
    N="${3:-1}"
    PROMPT="$(prompt_for_rag "${N}")"
    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "▶ RAG con trace — escenario ${N}"
    echo "  Prompt: ${PROMPT}"
    echo "────────────────────────────────────────────────────────"
    "${PYTHON_BIN}" invoke_agent.py --trace "${PROMPT}"
    exit 0
  fi

  rag_invoke() {
    local n="$1"
    local titulo="$2"
    local prompt
    prompt="$(prompt_for_rag "${n}")"
    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "▶ RAG ${n} — ${titulo}"
    echo "  Prompt: ${prompt}"
    echo "────────────────────────────────────────────────────────"
    "${PYTHON_BIN}" invoke_agent.py "${prompt}"
    echo ""
  }

  if [[ "${SUB2}" == "all" || "${SUB2}" == "1" ]]; then
    rag_invoke 1 "Política de devoluciones (info real-ish en la KB)"
  fi
  if [[ "${SUB2}" == "all" || "${SUB2}" == "2" ]]; then
    rag_invoke 2 "Programa TechCoins (datos demo en la KB)"
  fi
  if [[ "${SUB2}" == "all" || "${SUB2}" == "3" ]]; then
    rag_invoke 3 "Garantía de monitores (info real-ish en la KB)"
  fi
  if [[ "${SUB2}" == "all" || "${SUB2}" == "4" ]]; then
    rag_invoke 4 "Sucursal en Lima (NO está en la KB → debería rechazar)"
  fi

  if [[ "${SUB2}" != "all" && "${SUB2}" != "1" && "${SUB2}" != "2" && "${SUB2}" != "3" && "${SUB2}" != "4" ]]; then
    echo "❌ Subescenario RAG desconocido: ${SUB2}"
    echo "   Usa: bash test.sh rag | bash test.sh rag 1..4 | bash test.sh rag trace [N]"
    exit 1
  fi

  echo ""
  echo "✅ Escenarios RAG finalizados."
  exit 0
fi

if [[ "${SUBCMD}" == "rag-vs-chatbot" ]]; then
  PROMPT="$(prompt_for_rag 2)"  # TechCoins — algo que solo existe en nuestra KB
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo " A) Chatbot tradicional — sin RAG, sin herramientas"
  echo "    Prompt: ${PROMPT}"
  echo "════════════════════════════════════════════════════════"
  "${PYTHON_BIN}" invoke_chatbot.py "${PROMPT}"
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo " B) Agente Bedrock con Knowledge Base (RAG)"
  echo "    El agente buscará el programa TechCoins en la KB y citará la fuente."
  echo "════════════════════════════════════════════════════════"
  "${PYTHON_BIN}" invoke_agent.py "${PROMPT}"
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
  echo "   Usa: bash test.sh | bash test.sh 1|2|3 | bash test.sh trace [N]"
  echo "        bash test.sh chat | bash test.sh confirm | bash test.sh compare"
  echo "        bash test.sh rag [1..4|trace N] | bash test.sh rag-vs-chatbot"
  exit 1
fi

echo ""
echo "✅ Pruebas finalizadas."
