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

echo "==> Empaquetando Lambda demo web (chat_lambda.zip, Node.js sin npm install)..."
# El runtime Lambda Node.js 22 incluye @aws-sdk/* preinstalado, así que NO
# necesitamos npm install ni bundler: copiamos el .js a index.js y zipeamos.
rm -f chat_lambda.zip
(
  cd src-web
  cp chat_lambda.js index.js
  zip -q ../chat_lambda.zip index.js
  rm -f index.js
)
echo "==> Subiendo chat_lambda.zip a s3://${BUCKET_NAME}/..."
aws s3 cp chat_lambda.zip "s3://${BUCKET_NAME}/chat_lambda.zip" --region "${REGION}" >/dev/null

KB_PREFIX="kb-data/"
if [ -d "kb-data" ]; then
  echo "==> Subiendo documentos seed de la KB a s3://${BUCKET_NAME}/${KB_PREFIX}..."
  aws s3 sync kb-data/ "s3://${BUCKET_NAME}/${KB_PREFIX}" \
    --region "${REGION}" \
    --delete \
    --exclude "README.md" >/dev/null
  echo "    Documentos sincronizados."
else
  echo "⚠️  Carpeta kb-data/ no encontrada — la Knowledge Base quedará vacía."
fi

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
      KnowledgeBaseDataPrefix="${KB_PREFIX}" \
      AliasUpdateToken="${ALIAS_TOKEN}" \
      WebLambdaS3Key="chat_lambda.zip" \
  --region "${REGION}"

echo "==> Obteniendo outputs..."
AGENT_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='AgentId'].OutputValue" --output text)

ALIAS_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='AgentAliasId'].OutputValue" --output text)

KB_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='KnowledgeBaseId'].OutputValue" --output text)

DS_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='DataSourceId'].OutputValue" --output text)

CHAT_URL=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ChatFunctionUrl'].OutputValue" --output text)

FRONT_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendBucket'].OutputValue" --output text)

FRONT_URL=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendUrl'].OutputValue" --output text)

if [ -n "${FRONT_BUCKET}" ] && [ "${FRONT_BUCKET}" != "None" ] && [ -n "${CHAT_URL}" ] && [ "${CHAT_URL}" != "None" ]; then
  echo "==> Publicando sitio web estático en s3://${FRONT_BUCKET}/ ..."
  TMP_JS="$(mktemp)"
  export CHAT_URL TMP_JS
  python3 - <<'PY'
import os
from pathlib import Path
chat_url = os.environ["CHAT_URL"]
tmp = Path(os.environ["TMP_JS"])
src = Path("web/app.js").read_text(encoding="utf-8")
tmp.write_text(src.replace("__FUNCTION_URL__", chat_url), encoding="utf-8")
PY
  aws s3 sync web/ "s3://${FRONT_BUCKET}/" \
    --region "${REGION}" \
    --delete \
    --exclude "app.js" >/dev/null
  # Sin no-cache el navegador puede seguir sirviendo app.js viejo con __FUNCTION_URL__
  aws s3 cp "${TMP_JS}" "s3://${FRONT_BUCKET}/app.js" \
    --region "${REGION}" \
    --content-type "application/javascript; charset=utf-8" \
    --cache-control "no-cache, must-revalidate" >/dev/null
  rm -f "${TMP_JS}"
  echo "    Sitio sincronizado."
else
  echo "⚠️  No se pudo resolver FrontendBucket / ChatFunctionUrl; omite subida del sitio web."
fi

# ─────────────────────────────────────────────────────────────
# Ingesta inicial / re-ingesta (RAG)
# CloudFormation crea la KB y el DataSource pero no dispara la
# ingesta. La hacemos aquí, al final del deploy, para que los
# documentos estén indexados y el agente pueda recuperarlos.
# ─────────────────────────────────────────────────────────────
if [ -n "${KB_ID}" ] && [ -n "${DS_ID}" ]; then
  echo "==> Iniciando ingesta de la Knowledge Base (${KB_ID} / ${DS_ID})..."
  JOB_ID=$(aws bedrock-agent start-ingestion-job \
    --knowledge-base-id "${KB_ID}" \
    --data-source-id "${DS_ID}" \
    --description "Ingesta automática desde deploy.sh ${ALIAS_TOKEN}" \
    --region "${REGION}" \
    --query "ingestionJob.ingestionJobId" --output text)
  echo "    Job: ${JOB_ID} — esperando a COMPLETE (puede tardar 30-90 s)..."

  for _ in $(seq 1 30); do
    STATUS=$(aws bedrock-agent get-ingestion-job \
      --knowledge-base-id "${KB_ID}" \
      --data-source-id "${DS_ID}" \
      --ingestion-job-id "${JOB_ID}" \
      --region "${REGION}" \
      --query "ingestionJob.status" --output text 2>/dev/null || echo "UNKNOWN")
    case "${STATUS}" in
      COMPLETE)
        echo "    ✅ Ingesta COMPLETE."
        break ;;
      FAILED)
        echo "    ❌ Ingesta FAILED. Revisa logs en la consola de Bedrock."
        break ;;
      STARTING|IN_PROGRESS)
        sleep 5 ;;
      *)
        sleep 5 ;;
    esac
  done
fi

cat > agent.env <<EOF
export AGENT_ID="${AGENT_ID}"
export ALIAS_ID="${ALIAS_ID}"
export KNOWLEDGE_BASE_ID="${KB_ID}"
export DATA_SOURCE_ID="${DS_ID}"
export AWS_REGION="${REGION}"
EOF

echo ""
echo "✅ Despliegue completado."
echo "    Agent ID         : ${AGENT_ID}"
echo "    Alias ID         : ${ALIAS_ID}"
echo "    Knowledge Base   : ${KB_ID}"
echo "    Data Source      : ${DS_ID}"
if [ -n "${FRONT_URL}" ] && [ "${FRONT_URL}" != "None" ]; then
  echo ""
  echo "🌐 Frontend URL (sitio comparativo, HTTP): ${FRONT_URL}"
fi
if [ -n "${CHAT_URL}" ] && [ "${CHAT_URL}" != "None" ]; then
  echo "    Lambda Function URL (streaming):         ${CHAT_URL}"
fi
echo ""
echo "Para usar los IDs en tu shell actual, ejecuta:"
echo "    source agent.env"
