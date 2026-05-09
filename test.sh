#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Pruebas rápidas del Agente Autónomo.
# Requiere haber ejecutado deploy.sh y luego: source agent.env
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

REGION="${AWS_REGION:-us-east-1}"

invoke() {
  local titulo="$1"
  local prompt="$2"
  echo ""
  echo "────────────────────────────────────────────────────────"
  echo "▶ ${titulo}"
  echo "  Prompt: ${prompt}"
  echo "────────────────────────────────────────────────────────"
  aws bedrock-agent-runtime invoke-agent \
    --agent-id "${AGENT_ID}" \
    --agent-alias-id "${ALIAS_ID}" \
    --session-id "sesion-$(date +%s)-$$" \
    --input-text "${prompt}" \
    --region "${REGION}" \
    respuesta.json >/dev/null
  cat respuesta.json
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
