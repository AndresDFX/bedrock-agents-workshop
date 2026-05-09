#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Limpieza completa: borra el stack y el bucket S3 del taller.
# ─────────────────────────────────────────────────────────────

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="agente-soporte"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="workshop-agentes-${ACCOUNT_ID}"

# Vaciamos el bucket ANTES de borrar el stack porque, aunque CloudFormation
# no creó el bucket S3 normal (existe a nivel de cuenta), el stack tiene
# referencias a su contenido (lambda.zip + kb-data/). Limpiarlo después es
# más simple, pero hacerlo antes evita que la KB falle el delete si intenta
# leer durante la última ingesta.
echo "==> Vaciando bucket de documentos ${BUCKET_NAME} (lambda.zip + kb-data/)..."
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  aws s3 rm "s3://${BUCKET_NAME}" --recursive >/dev/null 2>&1 || true
fi

echo "==> Vaciando bucket del sitio web estático (FrontendBucket), si el stack existe..."
FRONT_BUCKET="$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendBucket'].OutputValue" --output text 2>/dev/null || true)"
if [ -n "${FRONT_BUCKET}" ] && [ "${FRONT_BUCKET}" != "None" ]; then
  aws s3 rm "s3://${FRONT_BUCKET}/" --recursive --region "${REGION}" >/dev/null 2>&1 || true
  echo "    Bucket web vaciado: ${FRONT_BUCKET}"
fi

echo "==> Eliminando stack ${STACK_NAME}..."
echo "    (incluye VectorIndex, VectorBucket de S3 Vectors, KB y DataSource)"
aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${REGION}"
aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" --region "${REGION}" || true

echo "==> Eliminando bucket S3 vacío ${BUCKET_NAME}..."
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  aws s3 rb "s3://${BUCKET_NAME}" --force >/dev/null 2>&1 || true
  echo "    Bucket eliminado."
else
  echo "    Bucket no existe (ok)."
fi

rm -f lambda.zip chat_lambda.zip agent.env

echo "✅ Limpieza completa. No se generarán más costos."
