#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Limpieza completa: borra el stack y el bucket S3 del taller.
# ─────────────────────────────────────────────────────────────

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="agente-soporte"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="workshop-agentes-${ACCOUNT_ID}"

echo "==> Eliminando stack ${STACK_NAME}..."
aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${REGION}"
aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" --region "${REGION}" || true

echo "==> Vaciando y borrando bucket ${BUCKET_NAME}..."
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  aws s3 rm "s3://${BUCKET_NAME}" --recursive >/dev/null || true
  aws s3 rb "s3://${BUCKET_NAME}" --force >/dev/null || true
  echo "    Bucket eliminado."
else
  echo "    Bucket no existe (ok)."
fi

rm -f lambda.zip agent.env

echo "✅ Limpieza completa. No se generarán más costos."
