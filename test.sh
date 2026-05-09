#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Pruebas rápidas del Agente Autónomo.
#
# Nota: la AWS CLI no expone el subcomando streaming
# `bedrock-agent-runtime invoke-agent` (es una operación con
# respuesta en stream). Por eso invocamos al agente con boto3
# desde Python (script invoke_agent.py).
#
# Uso:
#   ./test.sh         → corre los 3 escenarios
#   ./test.sh 1       → solo el escenario 1
#   ./test.sh 2       → solo el escenario 2
#   ./test.sh 3       → solo el escenario 3
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
  echo "   En CloudShell deberían estar disponibles por defecto."
  exit 1
fi

if ! "${PYTHON_BIN}" -c "import boto3" 2>/dev/null; then
  echo "ℹ️  Instalando boto3 para el usuario actual..."
  "${PYTHON_BIN}" -m pip install --quiet --user boto3
fi

invoke() {
  local titulo="$1"
  local prompt="$2"
  echo ""
  echo "────────────────────────────────────────────────────────"
  echo "▶ ${titulo}"
  echo "  Prompt: ${prompt}"
  echo "────────────────────────────────────────────────────────"
  "${PYTHON_BIN}" invoke_agent.py "${prompt}"
  echo ""
}

ESCENARIO="${1:-all}"

if [[ "${ESCENARIO}" == "all" || "${ESCENARIO}" == "1" ]]; then
  invoke "Escenario 1 — Consulta simple (1 herramienta)" \
    "¿Cuánto cuesta el monitor y cuántos hay en stock?"
fi

if [[ "${ESCENARIO}" == "all" || "${ESCENARIO}" == "2" ]]; then
  invoke "Escenario 2 — Flujo multi-paso autónomo (verifica + reembolsa)" \
    "Quiero un reembolso para mi pedido ORD-1001 porque el producto llegó dañado"
fi

if [[ "${ESCENARIO}" == "all" || "${ESCENARIO}" == "3" ]]; then
  invoke "Escenario 3 — Pedido no elegible (más de 30 días)" \
    "Necesito reembolso del pedido ORD-1004"
fi

echo ""
echo "✅ Pruebas finalizadas."
