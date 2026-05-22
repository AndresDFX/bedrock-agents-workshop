#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# destroy-students.sh
#
# Elimina los usuarios IAM creados por create-students.sh. Limpia, en orden:
#   1. Stacks CloudFormation que cada estudiante haya dejado sin destruir.
#   2. Buckets S3 huerfanos con prefijo "workshop-agentes-${USERNAME}-".
#   3. Login profile, access keys, group memberships.
#   4. El usuario IAM.
#   5. (Opcional) el grupo del workshop si queda vacio.
#
# Pre-requisitos:
#   AWS CLI configurada como admin / root.
#
# Variables de entorno opcionales:
#   NUM_USERS, START_INDEX, USER_PREFIX, GROUP_NAME, REGION
#   PURGE_STACKS=true|false  (default true) — destruye stacks restantes.
#   PURGE_BUCKETS=true|false (default true) — vacia y borra buckets huerfanos.
#   DELETE_GROUP=true|false  (default false) — borra el grupo al final si esta vacio.
# ---------------------------------------------------------------------------

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
NUM_USERS="${NUM_USERS:-50}"
START_INDEX="${START_INDEX:-1}"
USER_PREFIX="${USER_PREFIX:-estudiante}"
GROUP_NAME="${GROUP_NAME:-WorkshopStudents}"
PURGE_STACKS="${PURGE_STACKS:-true}"
PURGE_BUCKETS="${PURGE_BUCKETS:-true}"
DELETE_GROUP="${DELETE_GROUP:-false}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> Cuenta: ${ACCOUNT_ID} | Region: ${REGION}"
echo "==> Eliminando ${NUM_USERS} usuarios (${USER_PREFIX}$(printf '%02d' "${START_INDEX}").. ${USER_PREFIX}$(printf '%02d' $((START_INDEX + NUM_USERS - 1))))"
echo ""

END_INDEX=$((START_INDEX + NUM_USERS - 1))

# ---------------------------------------------------------------------------
# Fase 1: purgar stacks restantes por estudiante (si activado).
# ---------------------------------------------------------------------------
if [ "${PURGE_STACKS}" = "true" ]; then
  echo "==> Fase 1: destruyendo stacks restantes por estudiante..."
  for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
    USERNAME="${USER_PREFIX}$(printf '%02d' "${i}")"
    STACK_NAME="agente-soporte-${USERNAME}"

    STATUS=$(aws cloudformation describe-stacks \
      --stack-name "${STACK_NAME}" \
      --region "${REGION}" \
      --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "MISSING")

    if [ "${STATUS}" = "MISSING" ]; then
      continue
    fi

    echo "    [stack] ${STACK_NAME} — estado ${STATUS}, lanzando delete..."

    # Vacia bucket frontend antes de borrar el stack (si existe).
    FRONT_BUCKET=$(aws cloudformation describe-stacks \
      --stack-name "${STACK_NAME}" --region "${REGION}" \
      --query "Stacks[0].Outputs[?OutputKey=='FrontendBucket'].OutputValue" \
      --output text 2>/dev/null || true)
    if [ -n "${FRONT_BUCKET}" ] && [ "${FRONT_BUCKET}" != "None" ]; then
      aws s3 rm "s3://${FRONT_BUCKET}/" --recursive --region "${REGION}" >/dev/null 2>&1 || true
    fi

    aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${REGION}" 2>/dev/null || true
  done

  # Espera a que terminen los deletes.
  echo "    Esperando a que terminen los deletes (puede tardar unos minutos)..."
  for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
    USERNAME="${USER_PREFIX}$(printf '%02d' "${i}")"
    STACK_NAME="agente-soporte-${USERNAME}"
    aws cloudformation wait stack-delete-complete \
      --stack-name "${STACK_NAME}" --region "${REGION}" 2>/dev/null || true
  done
  echo "    Stacks procesados."
fi

# ---------------------------------------------------------------------------
# Fase 2: borrar buckets de assets huerfanos.
# ---------------------------------------------------------------------------
if [ "${PURGE_BUCKETS}" = "true" ]; then
  echo "==> Fase 2: borrando buckets de assets por estudiante..."
  for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
    USERNAME="${USER_PREFIX}$(printf '%02d' "${i}")"
    BUCKET="workshop-agentes-${USERNAME}-${ACCOUNT_ID}"

    if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
      aws s3 rm "s3://${BUCKET}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
      aws s3 rb "s3://${BUCKET}" --force --region "${REGION}" >/dev/null 2>&1 || true
      echo "    [bucket] eliminado ${BUCKET}"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Fase 3: eliminar usuarios IAM (login profile, keys, group memberships, user).
# ---------------------------------------------------------------------------
echo "==> Fase 3: eliminando usuarios IAM..."
DELETED=0
SKIPPED=0

for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
  USERNAME="${USER_PREFIX}$(printf '%02d' "${i}")"

  if ! aws iam get-user --user-name "${USERNAME}" >/dev/null 2>&1; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Login profile.
  aws iam delete-login-profile --user-name "${USERNAME}" >/dev/null 2>&1 || true

  # Access keys.
  for AKID in $(aws iam list-access-keys --user-name "${USERNAME}" \
                  --query "AccessKeyMetadata[].AccessKeyId" --output text 2>/dev/null); do
    [ -n "${AKID}" ] && aws iam delete-access-key \
      --user-name "${USERNAME}" --access-key-id "${AKID}" >/dev/null 2>&1 || true
  done

  # MFA devices.
  for MFA in $(aws iam list-mfa-devices --user-name "${USERNAME}" \
                  --query "MFADevices[].SerialNumber" --output text 2>/dev/null); do
    [ -n "${MFA}" ] && aws iam deactivate-mfa-device \
      --user-name "${USERNAME}" --serial-number "${MFA}" >/dev/null 2>&1 || true
  done

  # Group memberships.
  for GRP in $(aws iam list-groups-for-user --user-name "${USERNAME}" \
                  --query "Groups[].GroupName" --output text 2>/dev/null); do
    [ -n "${GRP}" ] && aws iam remove-user-from-group \
      --user-name "${USERNAME}" --group-name "${GRP}" >/dev/null 2>&1 || true
  done

  # Policies directas (inline + attached).
  for POL in $(aws iam list-user-policies --user-name "${USERNAME}" \
                  --query "PolicyNames" --output text 2>/dev/null); do
    [ -n "${POL}" ] && aws iam delete-user-policy \
      --user-name "${USERNAME}" --policy-name "${POL}" >/dev/null 2>&1 || true
  done
  for POL_ARN in $(aws iam list-attached-user-policies --user-name "${USERNAME}" \
                      --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
    [ -n "${POL_ARN}" ] && aws iam detach-user-policy \
      --user-name "${USERNAME}" --policy-arn "${POL_ARN}" >/dev/null 2>&1 || true
  done

  # Permission boundary attached al user (no es policy, es config).
  aws iam delete-user-permissions-boundary --user-name "${USERNAME}" >/dev/null 2>&1 || true

  # Finalmente borra el usuario.
  if aws iam delete-user --user-name "${USERNAME}" 2>/dev/null; then
    echo "    [delete] ${USERNAME}"
    DELETED=$((DELETED + 1))
  else
    echo "    [error]  ${USERNAME} — no se pudo borrar (revisa dependencias)"
  fi
done

# ---------------------------------------------------------------------------
# Fase 4: opcional, borrar el grupo si quedo vacio.
# ---------------------------------------------------------------------------
if [ "${DELETE_GROUP}" = "true" ]; then
  echo "==> Fase 4: borrando grupo ${GROUP_NAME}..."
  if aws iam get-group --group-name "${GROUP_NAME}" >/dev/null 2>&1; then
    # Detach policies del grupo.
    for POL_ARN in $(aws iam list-attached-group-policies --group-name "${GROUP_NAME}" \
                        --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
      [ -n "${POL_ARN}" ] && aws iam detach-group-policy \
        --group-name "${GROUP_NAME}" --policy-arn "${POL_ARN}" >/dev/null 2>&1 || true
    done
    aws iam delete-group --group-name "${GROUP_NAME}" >/dev/null 2>&1 || true
    echo "    Grupo eliminado."
  fi
fi

echo ""
echo "✅ Limpieza completa."
echo "    Borrados: ${DELETED}"
echo "    No existian: ${SKIPPED}"
echo ""
echo "ℹ️  La policy de boundary (WorkshopBoundaryPolicy) NO se borra automaticamente."
echo "   Si la quieres eliminar:"
echo "     aws cloudformation delete-stack --stack-name workshop-boundary --region ${REGION}"
