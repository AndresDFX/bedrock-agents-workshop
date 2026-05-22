#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# recover-boundary.sh
#
# Cuando el stack workshop-boundary queda en un estado roto (ROLLBACK_COMPLETE,
# UPDATE_FAILED, UPDATE_ROLLBACK_FAILED, etc.) este script limpia el desastre:
#
#   1. Detacha el Permission Boundary de todos los usuarios del workshop
#      (estudiante01..NN y ponente-test). Sin esto no se puede borrar la policy.
#   2. Borra el stack CloudFormation 'workshop-boundary'.
#   3. Si quedo la policy huerfana en IAM, la borra (todas las versiones).
#   4. Lanza create-students.sh para recrear todo limpio:
#      - re-deploy del stack del boundary
#      - re-aplica el boundary a los usuarios existentes
#
# Variables opcionales:
#   BOUNDARY_NAME           default 'WorkshopBoundaryPolicy'
#   BOUNDARY_STACK_NAME     default 'workshop-boundary'
#   USER_PREFIX             default 'estudiante'
#   TEST_USER_NAME          default 'ponente-test'
#   SKIP_RECREATE=true      no llama a create-students.sh al final
# ---------------------------------------------------------------------------

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
BOUNDARY_NAME="${BOUNDARY_NAME:-WorkshopBoundaryPolicy}"
BOUNDARY_STACK_NAME="${BOUNDARY_STACK_NAME:-workshop-boundary}"
USER_PREFIX="${USER_PREFIX:-estudiante}"
TEST_USER_NAME="${TEST_USER_NAME:-ponente-test}"
SKIP_RECREATE="${SKIP_RECREATE:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BOUNDARY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${BOUNDARY_NAME}"

echo "==> Recovery del workshop boundary"
echo "    Cuenta:       ${ACCOUNT_ID}"
echo "    Region:       ${REGION}"
echo "    Stack:        ${BOUNDARY_STACK_NAME}"
echo "    Policy:       ${BOUNDARY_NAME}"
echo ""

# ---------------------------------------------------------------------------
# Paso 1: detachear boundary de TODOS los usuarios que lo tengan attached.
# Lo hacemos por listado IAM directo (no por convencion de nombre) para
# cubrir cualquier user que tenga este boundary, incluso si no lo creamos
# nosotros.
# ---------------------------------------------------------------------------
echo "==> Paso 1: detacheando boundary de usuarios..."
DETACHED=0
for username in $(aws iam list-users --query "Users[].UserName" --output text); do
  CURRENT=$(aws iam get-user --user-name "${username}" \
    --query 'User.PermissionsBoundary.PermissionsBoundaryArn' \
    --output text 2>/dev/null || echo "")

  if [ "${CURRENT}" = "${BOUNDARY_ARN}" ]; then
    aws iam delete-user-permissions-boundary --user-name "${username}" 2>/dev/null || true
    echo "    [detach] ${username}"
    DETACHED=$((DETACHED + 1))
  fi
done
echo "    Detachados: ${DETACHED} usuarios"
echo ""

# ---------------------------------------------------------------------------
# Paso 2: borrar el stack si existe. Si esta en cualquier estado raro, el
# delete-stack normalmente funciona; si no, hay que arreglarlo manual.
# ---------------------------------------------------------------------------
echo "==> Paso 2: borrando stack ${BOUNDARY_STACK_NAME}..."
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "${BOUNDARY_STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "MISSING")

if [ "${STACK_STATUS}" = "MISSING" ]; then
  echo "    Stack no existe (ok)."
else
  echo "    Estado actual: ${STACK_STATUS}"

  # Si esta en UPDATE_ROLLBACK_FAILED, hay que hacer continue-update-rollback primero.
  if [ "${STACK_STATUS}" = "UPDATE_ROLLBACK_FAILED" ]; then
    echo "    Intentando continue-update-rollback..."
    aws cloudformation continue-update-rollback \
      --stack-name "${BOUNDARY_STACK_NAME}" \
      --region "${REGION}" 2>/dev/null || true
    aws cloudformation wait stack-rollback-complete \
      --stack-name "${BOUNDARY_STACK_NAME}" \
      --region "${REGION}" 2>/dev/null || true
  fi

  aws cloudformation delete-stack \
    --stack-name "${BOUNDARY_STACK_NAME}" \
    --region "${REGION}"
  echo "    Esperando delete-complete..."
  aws cloudformation wait stack-delete-complete \
    --stack-name "${BOUNDARY_STACK_NAME}" \
    --region "${REGION}" || true
  echo "    Stack eliminado."
fi
echo ""

# ---------------------------------------------------------------------------
# Paso 3: borrar la policy huerfana si quedo en IAM fuera de CFN.
# ---------------------------------------------------------------------------
echo "==> Paso 3: verificando si quedo la policy huerfana en IAM..."
POL_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='${BOUNDARY_NAME}'].Arn" \
  --output text 2>/dev/null || echo "")

if [ -z "${POL_ARN}" ] || [ "${POL_ARN}" = "None" ]; then
  echo "    No quedo policy huerfana (ok)."
else
  echo "    Policy huerfana encontrada: ${POL_ARN}"
  echo "    Borrando versiones non-default..."
  for VID in $(aws iam list-policy-versions \
                  --policy-arn "${POL_ARN}" \
                  --query "Versions[?!IsDefaultVersion].VersionId" \
                  --output text 2>/dev/null); do
    [ -n "${VID}" ] && aws iam delete-policy-version \
      --policy-arn "${POL_ARN}" --version-id "${VID}" 2>/dev/null || true
  done

  echo "    Borrando policy..."
  aws iam delete-policy --policy-arn "${POL_ARN}" 2>/dev/null || {
    echo ""
    echo "❌ No se pudo borrar la policy. Causas posibles:"
    echo "   - Sigue attached a algun usuario/rol (revisa con 'aws iam list-entities-for-policy --policy-arn ${POL_ARN}')."
    echo "   - Permisos insuficientes (debes correr como admin/root)."
    exit 1
  }
  echo "    Policy borrada."
fi
echo ""

# ---------------------------------------------------------------------------
# Paso 4: recrear todo via create-students.sh
# ---------------------------------------------------------------------------
if [ "${SKIP_RECREATE}" = "true" ]; then
  echo "✅ Limpieza completa. SKIP_RECREATE=true, no relanzo create-students.sh."
  echo "   Para terminar el setup corre manualmente:"
  echo "     bash ${SCRIPT_DIR}/create-students.sh"
  exit 0
fi

echo "==> Paso 4: relanzando create-students.sh..."
echo ""
bash "${SCRIPT_DIR}/create-students.sh"

echo ""
echo "✅ Recovery completo. Stack del boundary recreado, policy nueva, usuarios re-asociados."
