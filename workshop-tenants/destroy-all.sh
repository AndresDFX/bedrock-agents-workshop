#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# destroy-all.sh
#
# Cleanup TOTAL del setup multi-tenant. Borra:
#   - Todos los stacks de estudiantes (agente-soporte-${USER}).
#   - Todos los buckets de assets (workshop-agentes-${USER}-${ACCOUNT}).
#   - Todos los usuarios IAM con tag Workshop=BedrockAgents2026 (incluye
#     ponente-test y cualquier estudianteNN, incluso fuera del rango 01-60).
#   - El grupo IAM WorkshopStudents.
#   - El stack workshop-boundary (que borra la policy WorkshopBoundaryPolicy).
#
# Despues de correr este script tu cuenta queda como antes del setup.
#
# Variables opcionales:
#   BOUNDARY_STACK_NAME    default 'workshop-boundary'
#   GROUP_NAME             default 'WorkshopStudents'
#   WORKSHOP_TAG_KEY       default 'Workshop'
#   WORKSHOP_TAG_VALUE     default 'BedrockAgents2026'
#   FORCE                  default 'false'. Pon 'true' para saltar confirmacion.
# ---------------------------------------------------------------------------

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
BOUNDARY_STACK_NAME="${BOUNDARY_STACK_NAME:-workshop-boundary}"
GROUP_NAME="${GROUP_NAME:-WorkshopStudents}"
WORKSHOP_TAG_KEY="${WORKSHOP_TAG_KEY:-Workshop}"
WORKSHOP_TAG_VALUE="${WORKSHOP_TAG_VALUE:-BedrockAgents2026}"
FORCE="${FORCE:-false}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==================================================================="
echo "  CLEANUP TOTAL del workshop multi-tenant"
echo "==================================================================="
echo "  Cuenta:          ${ACCOUNT_ID}"
echo "  Region:          ${REGION}"
echo "  Tag filter:      ${WORKSHOP_TAG_KEY}=${WORKSHOP_TAG_VALUE}"
echo "  Grupo IAM:       ${GROUP_NAME}"
echo "  Stack boundary:  ${BOUNDARY_STACK_NAME}"
echo "==================================================================="
echo ""

# ---------------------------------------------------------------------------
# Confirmacion (a menos que FORCE=true)
# ---------------------------------------------------------------------------
if [ "${FORCE}" != "true" ]; then
  echo "Esto va a BORRAR todo lo del setup multi-tenant. Irreversible."
  read -p "Confirma escribiendo 'BORRAR': " CONFIRM
  if [ "${CONFIRM}" != "BORRAR" ]; then
    echo "Cancelado."
    exit 0
  fi
  echo ""
fi

# ---------------------------------------------------------------------------
# Paso 1: descubrir usuarios del workshop via tag.
# ---------------------------------------------------------------------------
echo "==> Paso 1: descubriendo usuarios con tag ${WORKSHOP_TAG_KEY}=${WORKSHOP_TAG_VALUE}..."
USERNAMES=()
for user in $(aws iam list-users --query "Users[].UserName" --output text); do
  TAGS=$(aws iam list-user-tags --user-name "${user}" \
           --query "Tags[?Key=='${WORKSHOP_TAG_KEY}'].Value" \
           --output text 2>/dev/null || echo "")
  if [ "${TAGS}" = "${WORKSHOP_TAG_VALUE}" ]; then
    USERNAMES+=("${user}")
  fi
done

echo "    Encontrados: ${#USERNAMES[@]} usuarios"
if [ ${#USERNAMES[@]} -eq 0 ]; then
  echo "    (nada que borrar; sigo con el cleanup de boundary por si quedo)"
fi
echo ""

# ---------------------------------------------------------------------------
# Paso 2: borrar stack + bucket de cada usuario en paralelo (best-effort).
# ---------------------------------------------------------------------------
echo "==> Paso 2: lanzando delete-stack para cada usuario..."
for user in "${USERNAMES[@]}"; do
  STACK="agente-soporte-${user}"
  STATUS=$(aws cloudformation describe-stacks --stack-name "${STACK}" \
             --region "${REGION}" --query "Stacks[0].StackStatus" \
             --output text 2>/dev/null || echo "MISSING")

  if [ "${STATUS}" = "MISSING" ]; then
    continue
  fi

  # Vaciar bucket frontend si existe
  FRONT=$(aws cloudformation describe-stacks --stack-name "${STACK}" \
            --region "${REGION}" \
            --query "Stacks[0].Outputs[?OutputKey=='FrontendBucket'].OutputValue" \
            --output text 2>/dev/null || true)
  if [ -n "${FRONT}" ] && [ "${FRONT}" != "None" ]; then
    aws s3 rm "s3://${FRONT}/" --recursive --region "${REGION}" >/dev/null 2>&1 || true
  fi

  aws cloudformation delete-stack --stack-name "${STACK}" --region "${REGION}" 2>/dev/null || true
  echo "    [stack] delete iniciado: ${STACK}"
done

echo ""
echo "==> Esperando a que terminen los deletes de stacks..."
for user in "${USERNAMES[@]}"; do
  STACK="agente-soporte-${user}"
  aws cloudformation wait stack-delete-complete --stack-name "${STACK}" \
    --region "${REGION}" 2>/dev/null || true
done
echo "    Stacks procesados."
echo ""

# ---------------------------------------------------------------------------
# Paso 3: borrar buckets de assets (workshop-agentes-USER-ACCOUNT)
# ---------------------------------------------------------------------------
echo "==> Paso 3: borrando buckets de assets por usuario..."
for user in "${USERNAMES[@]}"; do
  BUCKET="workshop-agentes-${user}-${ACCOUNT_ID}"
  if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
    aws s3 rm "s3://${BUCKET}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
    aws s3 rb "s3://${BUCKET}" --force --region "${REGION}" >/dev/null 2>&1 || true
    echo "    [bucket] eliminado ${BUCKET}"
  fi
done
echo ""

# ---------------------------------------------------------------------------
# Paso 4: borrar usuarios IAM (login profile, keys, MFA, group, policies, user)
# ---------------------------------------------------------------------------
echo "==> Paso 4: borrando usuarios IAM..."
for user in "${USERNAMES[@]}"; do
  # Login profile
  aws iam delete-login-profile --user-name "${user}" >/dev/null 2>&1 || true

  # Access keys
  for akid in $(aws iam list-access-keys --user-name "${user}" \
                  --query "AccessKeyMetadata[].AccessKeyId" --output text 2>/dev/null); do
    [ -n "${akid}" ] && aws iam delete-access-key \
      --user-name "${user}" --access-key-id "${akid}" >/dev/null 2>&1 || true
  done

  # MFA
  for mfa in $(aws iam list-mfa-devices --user-name "${user}" \
                  --query "MFADevices[].SerialNumber" --output text 2>/dev/null); do
    [ -n "${mfa}" ] && aws iam deactivate-mfa-device \
      --user-name "${user}" --serial-number "${mfa}" >/dev/null 2>&1 || true
  done

  # Groups
  for grp in $(aws iam list-groups-for-user --user-name "${user}" \
                  --query "Groups[].GroupName" --output text 2>/dev/null); do
    [ -n "${grp}" ] && aws iam remove-user-from-group \
      --user-name "${user}" --group-name "${grp}" >/dev/null 2>&1 || true
  done

  # Inline policies
  for pol in $(aws iam list-user-policies --user-name "${user}" \
                  --query "PolicyNames" --output text 2>/dev/null); do
    [ -n "${pol}" ] && aws iam delete-user-policy \
      --user-name "${user}" --policy-name "${pol}" >/dev/null 2>&1 || true
  done

  # Attached policies
  for pol_arn in $(aws iam list-attached-user-policies --user-name "${user}" \
                      --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
    [ -n "${pol_arn}" ] && aws iam detach-user-policy \
      --user-name "${user}" --policy-arn "${pol_arn}" >/dev/null 2>&1 || true
  done

  # Permission boundary
  aws iam delete-user-permissions-boundary --user-name "${user}" >/dev/null 2>&1 || true

  # User
  if aws iam delete-user --user-name "${user}" 2>/dev/null; then
    echo "    [delete] ${user}"
  else
    echo "    [error]  ${user} — revisa dependencias"
  fi
done
echo ""

# ---------------------------------------------------------------------------
# Paso 5: borrar el grupo IAM
# ---------------------------------------------------------------------------
echo "==> Paso 5: borrando grupo IAM ${GROUP_NAME}..."
if aws iam get-group --group-name "${GROUP_NAME}" >/dev/null 2>&1; then
  for pol_arn in $(aws iam list-attached-group-policies --group-name "${GROUP_NAME}" \
                      --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
    [ -n "${pol_arn}" ] && aws iam detach-group-policy \
      --group-name "${GROUP_NAME}" --policy-arn "${pol_arn}" >/dev/null 2>&1 || true
  done
  aws iam delete-group --group-name "${GROUP_NAME}" >/dev/null 2>&1 || true
  echo "    Grupo eliminado."
else
  echo "    Grupo no existe (ok)."
fi
echo ""

# ---------------------------------------------------------------------------
# Paso 6: borrar el stack workshop-boundary (borra tambien la policy)
# ---------------------------------------------------------------------------
echo "==> Paso 6: borrando stack ${BOUNDARY_STACK_NAME}..."
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "${BOUNDARY_STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "MISSING")

if [ "${STACK_STATUS}" = "MISSING" ]; then
  echo "    Stack no existe (ok)."
else
  aws cloudformation delete-stack --stack-name "${BOUNDARY_STACK_NAME}" --region "${REGION}"
  aws cloudformation wait stack-delete-complete \
    --stack-name "${BOUNDARY_STACK_NAME}" --region "${REGION}" 2>/dev/null || true
  echo "    Stack ${BOUNDARY_STACK_NAME} eliminado."
fi
echo ""

# ---------------------------------------------------------------------------
# Paso 7: verificar que la policy quedo limpia (por si quedo huerfana)
# ---------------------------------------------------------------------------
echo "==> Paso 7: verificando que la policy del boundary este borrada..."
POL_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='WorkshopBoundaryPolicy'].Arn" \
  --output text 2>/dev/null || echo "")

if [ -z "${POL_ARN}" ] || [ "${POL_ARN}" = "None" ]; then
  echo "    Policy borrada (ok)."
else
  echo "    Policy quedo huerfana: ${POL_ARN}"
  echo "    Borrando versiones non-default..."
  for VID in $(aws iam list-policy-versions --policy-arn "${POL_ARN}" \
                  --query "Versions[?!IsDefaultVersion].VersionId" \
                  --output text 2>/dev/null); do
    [ -n "${VID}" ] && aws iam delete-policy-version \
      --policy-arn "${POL_ARN}" --version-id "${VID}" 2>/dev/null || true
  done
  aws iam delete-policy --policy-arn "${POL_ARN}" 2>/dev/null && \
    echo "    Policy borrada." || \
    echo "    ❌ No se pudo borrar la policy. Revisa attachments residuales."
fi
echo ""

# ---------------------------------------------------------------------------
# Limpieza local opcional
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/students.csv" ]; then
  rm -f "${SCRIPT_DIR}/students.csv"
  echo "    Eliminado students.csv local."
fi
if [ -f "${SCRIPT_DIR}/students-summary.txt" ]; then
  rm -f "${SCRIPT_DIR}/students-summary.txt"
  echo "    Eliminado students-summary.txt local."
fi

echo ""
echo "✅ Cleanup TOTAL completo."
echo "   La cuenta quedo como antes del setup multi-tenant."
echo "   Para volver a crear todo: bash create-students.sh"
