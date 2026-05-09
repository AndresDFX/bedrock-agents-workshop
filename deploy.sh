#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Despliegue automático del Agente Autónomo (Bedrock + CFN)
# Pensado para ejecutarse 100% desde AWS CloudShell.
# ─────────────────────────────────────────────────────────────

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="agente-soporte"
PROJECT_NAME="techstore-agente"

echo "==> Verificando credenciales AWS..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "    Cuenta: ${ACCOUNT_ID}"
echo "    Region: ${REGION}"

BUCKET_NAME="workshop-agentes-${ACCOUNT_ID}"

echo "==> Asegurando bucket S3 (${BUCKET_NAME})..."
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "    Bucket ya existe."
else
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
  echo "    Bucket creado."
fi

echo "==> Empaquetando Lambda (lambda.zip)..."
rm -f lambda.zip
( cd src && zip -q -r ../lambda.zip lambda_function.py )

echo "==> Subiendo lambda.zip a s3://${BUCKET_NAME}/..."
aws s3 cp lambda.zip "s3://${BUCKET_NAME}/lambda.zip" --region "${REGION}" >/dev/null

ALIAS_TOKEN="$(date +%s)"
echo "==> Desplegando stack CloudFormation (${STACK_NAME})..."
echo "    AliasUpdateToken=${ALIAS_TOKEN} (fuerza nueva versión del agente)"
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name "${STACK_NAME}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      BucketName="${BUCKET_NAME}" \
      ProjectName="${PROJECT_NAME}" \
      AliasUpdateToken="${ALIAS_TOKEN}" \
  --region "${REGION}"

echo "==> Obteniendo outputs..."
AGENT_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='AgentId'].OutputValue" --output text)

ALIAS_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='AgentAliasId'].OutputValue" --output text)

cat > agent.env <<EOF
export AGENT_ID="${AGENT_ID}"
export ALIAS_ID="${ALIAS_ID}"
export AWS_REGION="${REGION}"
EOF

echo ""
echo "✅ Despliegue completado."
echo "    Agent ID : ${AGENT_ID}"
echo "    Alias ID : ${ALIAS_ID}"
echo ""
echo "Para usar los IDs en tu shell actual, ejecuta:"
echo "    source agent.env"
