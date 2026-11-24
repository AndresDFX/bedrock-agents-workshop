# Workshop Multi-Tenant — Setup para el ponente

> ⚠️ **Esto NO es para los participantes.** Esta carpeta contiene los scripts y plantillas que **el ponente** ejecuta UNA SOLA VEZ antes del evento para provisionar **60 usuarios IAM** + **1 usuario de prueba (`ponente-test`)** dentro de su propia cuenta AWS. Los participantes simplemente usan su `estudianteNN` + password, abren CloudShell y siguen [la guía del taller](../README.md) como cualquier participante.

## Qué hace este directorio

Provisiona **60 entornos de participante + 1 usuario de prueba** dentro de una sola cuenta AWS (separados por nombre, no por permisos: ver «Aislamiento entre estudiantes») usando:
- **Permission Boundary permisivo**: Allow universal (todos los servicios AWS funcionan), Deny solo sobre **escalación IAM** (no pueden crear otros usuarios / hacerse admin entre ellos) y **billing/organization** (no pueden cambiar plan, vincular cuentas, etc.). El ponente asume el costo de uso.
- **Usuarios IAM individuales**: cada participante recibe `estudianteNN` + password genérica (NN = 01..60).
- **Usuario de prueba (`ponente-test`)**: idéntico a un estudiante pero con nombre distinto, para que **TÚ** valides el flujo end-to-end antes del evento sin "gastar" una cuenta de estudiante.
- **Sufijo único por usuario** en `deploy.sh`: detecta el `IAM_USER` actual y nombra todos los recursos con sufijo (`agente-soporte-estudiante07`, `workshop-agentes-estudiante07-XXX`, etc.). Los 60 stacks + el de prueba coexisten sin colisión.

## Cuándo usar este enfoque

✅ **Cuando tiene sentido:**
- No conseguiste AWS Workshop Studio ni vouchers.
- No quieres exigir cuenta AWS personal a los participantes.
- Estás dispuesto a absorber USD 10–30 de Bedrock para los 60.
- Tienes una cuenta AWS dedicada al workshop (recomendado), no tu cuenta personal con datos sensibles.

❌ **Cuando NO usarlo:**
- Si te aprobaron Workshop Studio → úsalo, es mejor.
- Si los participantes ya van a tener su propia cuenta → guía actual sin esto.
- Si tu cuenta tiene workloads de producción mezclados → riesgo de blast radius.

## Archivos

| Archivo | Propósito |
|---|---|
| `boundary-stack.yaml` | CFN stack que crea la `WorkshopBoundaryPolicy` (Permission Boundary). |
| `create-students.sh` | Crea los 60 estudiantes + 1 usuario de prueba (`ponente-test`) con boundary, password genérica, grupo. Genera `students.csv`. |
| `destroy-students.sh` | Borra los 60 usuarios y sus recursos huérfanos (stacks, buckets). El `ponente-test` se conserva salvo que pases `DELETE_TEST_USER=true`. |
| `destroy-all.sh` | **Cleanup TOTAL**: descubre usuarios por tag `Workshop=BedrockAgents2026` (incluye `ponente-test` y cualquier `estudianteNN`), borra sus stacks/buckets, los usuarios, el grupo `WorkshopStudents`, el stack del boundary y la policy. Pide confirmación escribiendo `BORRAR` (salta con `FORCE=true`). |
| `recover-boundary.sh` | **Solo si el stack del boundary queda en estado roto** (ROLLBACK_COMPLETE, UPDATE_FAILED por "AlreadyExists", etc.). Detacha el boundary de todos los usuarios, borra el stack, borra la policy huérfana y relanza `create-students.sh` desde cero. |
| `students.csv` | (Generado) lista `username,password,console_url` para repartir. |
| `students-summary.txt` | (Generado) resumen con la URL de login. |

## Flujo completo

### Pre-evento (1 semana antes)

**Todo lo de IAM (boundary + 60 estudiantes + `ponente-test`) en UN solo comando:**

```bash
cd workshop-tenants
bash create-students.sh
```

El script ahora:
1. **Despliega o actualiza** `boundary-stack.yaml` automáticamente cada vez que lo corres (idempotente: si el stack ya existe sin cambios, dice "No changes" y sigue).
2. Crea el grupo `WorkshopStudents` con `AdministratorAccess` (intersectado por el boundary).
3. Crea **60 usuarios `estudiante01..estudiante60`** + **1 usuario `ponente-test`** (para tu validación pre-evento).
4. Genera `students.csv` con `username,password,console_url` por cada uno.

> **Nota:** los participantes en multi-tenant usan prefijo corto `ts-${USER}` en el `ProjectName` (no `techstore-${USER}`) porque el límite de 64 chars en `RoleName` de IAM no daba para más largos. En single-tenant se mantiene `techstore-agente`.

Salida final: `students.csv` con 61 filas. La **última fila es `ponente-test`** — no la repartas, es para ti.

**Pasos manuales que solo hace una vez el ponente** (fuera de este script):
- (Opcional) Habilita **Sonnet 4.5** y **Titan v2** en Bedrock (Model catalog → Open in Playground). Los estudiantes heredan el acceso de la cuenta.
- (Opcional) Pide aumento de cuota de Sonnet 4.5 si esperas 60 invocaciones paralelas: Service Quotas → Amazon Bedrock → "On-demand model inference requests per minute".

### Día del evento

1. **Reparte el CSV** o proyecta una pantalla con la tabla `username → password → login_url`. Cada participante toma una fila (uno por persona, sin duplicar).
2. **Anuncia** la URL de login (`https://<ACCOUNT_ID>.signin.aws.amazon.com/console`) y la password genérica.
3. Cada participante:
   - Entra a la consola con su `estudianteNN`.
   - Abre **CloudShell**.
   - `git clone https://github.com/AndresDFX/bedrock-agents-workshop.git`
   - `cd bedrock-agents-workshop && bash deploy.sh`
   - Sigue [la guía del taller](../README.md).

**El `deploy.sh` detecta automáticamente que estás como `estudiante07`** y nombra todos los recursos con ese sufijo. Los 60 stacks (más el de `ponente-test` si lo dejaste) no colisionan entre sí.

### Post-evento (mismo día o al día siguiente)

```bash
cd workshop-tenants

# 1. Destruye TODOS los stacks de los estudiantes (los que no corrieron destroy.sh).
# 2. Borra usuarios IAM, login profiles, group memberships.
# 3. Borra buckets S3 huérfanos.
bash destroy-students.sh

# 4. (Opcional) Borra la policy de boundary si no vas a volver a usarla.
aws cloudformation delete-stack --stack-name workshop-boundary --region us-east-1
```

## Cómo funciona la seguridad

### Permission Boundary (la jaula)

La policy `WorkshopBoundaryPolicy` (definida en `boundary-stack.yaml`) declara tres sentencias:

1. **Allow universal** (`AllowAllForWorkshop`, `Action: '*'`): el ponente asume el costo y los participantes pueden usar cualquier servicio que necesite el taller (Bedrock, Lambda, S3 Vectors, KMS, CloudFormation…).
2. **Deny condicional** (`BloquearCrearRolesSinBoundary`): niega `iam:CreateRole`, `iam:PutRolePolicy` e `iam:AttachRolePolicy` si el rol no lleva este mismo boundary. Sin esto, un estudiante creativo podría crear un rol "admin" y asignárselo a una Lambda para escapar.
3. **Deny de escalación y facturación** (`BloquearEscalacionYBilling`): crear o modificar usuarios, grupos, políticas, llaves de acceso, login profiles y boundaries de usuario; la federación STS (`AssumeRoleWithWebIdentity`, `AssumeRoleWithSAML`); y todo lo de cuenta, organización y facturación (`organizations`, `account`, `aws-portal`, `billing`, `budgets`, `savingsplans`, `ce`, `cur`).

**No hay lista de servicios vetados:** EC2, RDS, SageMaker, OpenSearch y el resto están permitidos. El costo se controla con la cuota de Bedrock, una alarma de facturación y el borrado al final del evento.

**Regla AWS:** el permiso efectivo de un usuario con boundary es **la intersección** entre las políticas que tiene (en este caso `AdministratorAccess`) y el boundary. Aunque parezca admin, el boundary lo limita.

### El truco del Permission Boundary en CFN

El `template.yaml` del workshop usa `CAPABILITY_NAMED_IAM` y crea 4 roles. Para que un estudiante pueda crear esos roles **sin escapar del sandbox**, el template **inyecta el boundary** en cada rol que crea (via parámetro `PermissionsBoundaryArn`). `deploy.sh` lo pasa automáticamente.

Si un estudiante intentara crear un rol manualmente sin boundary → recibe `AccessDeniedException` por la condición `iam:PermissionsBoundary` en la policy.

### Aislamiento entre estudiantes

El aislamiento es **por nombre, no por permisos**:
- Cada estudiante crea sus recursos con su sufijo (stacks, buckets, roles, agente), así que los 60 despliegues no chocan.
- Pero el boundary **no** separa a unos estudiantes de otros. Con `AdministratorAccess` y el Allow universal, cualquiera puede listar, leer, modificar o borrar el stack, el bucket o el agente de otro. Lo único vetado es IAM (usuarios, grupos, políticas), la federación y la facturación.
- Para un taller con personas de confianza, en una cuenta dedicada que se borra al terminar, es aceptable. Si no lo es, usa Workshop Studio o una cuenta por participante.

## Costos esperados

| Concepto | Estimado |
|---|---|
| Bedrock Sonnet 4.5 (60 personas × ~5 prompts) | USD 7–18 |
| Bedrock Titan v2 embeddings (60 ingestas iniciales) | < USD 0.50 |
| S3 Vectors (60 índices pequeños durante 1 día) | < USD 1 |
| Lambda + API Gateway + S3 + CloudWatch | < USD 1 |
| **Total** | **USD 10–20** |

**Optimización:** corre `destroy-students.sh` el mismo día del evento. Cada hora extra con 60 stacks idle suma centavos por S3 Vectors.

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Throttling de Bedrock con 60 personas simultáneas | Pide aumento de quota antes del evento. Cross-region inference profile (`us.*`) ya está activo y reparte carga. |
| Un estudiante crea un loop infinito de invocaciones o lanza servicios caros | El boundary **no** limita servicios. Bedrock tiene quota por cuenta; configura antes una alarma de CloudWatch sobre `EstimatedCharges` (o un AWS Budget) y borra todo al terminar. |
| Cuotas de cuenta: 61 KBs, 61 agentes, 61 VectorBuckets (60 estudiantes + `ponente-test`) | Verifica cuotas antes: `aws service-quotas list-service-quotas --service-code bedrock`. Si alguna no alcanza, pide aumento. |
| Estudiante deja recursos sin destruir | `destroy-students.sh` los limpia todos automáticamente. |
| Un participante comparte sus credenciales fuera del evento | Password expira / cámbiala / borra el usuario después. Considera MFA pero complica el setup. |

## FAQ

**P: ¿Tengo que ser admin AWS para correr `create-students.sh`?**
R: Necesitas permisos para `iam:CreateUser`, `iam:CreateLoginProfile`, `iam:CreateGroup`, `iam:AttachGroupPolicy`. AdminAccess o un rol equivalente funciona.

**P: ¿Funciona en una cuenta que ya tiene workloads en producción?**
R: **No.** El boundary es permisivo: los estudiantes pueden ver y modificar casi cualquier recurso de la cuenta (todo menos IAM y facturación). Usa una cuenta dedicada al taller.

**P: ¿Y si un estudiante olvida `bash destroy.sh` y se va?**
R: Tu `destroy-students.sh` los limpia automáticamente al final. Tu costo total termina igual.

**P: ¿Puedo correr esto en una cuenta gratuita / Free Tier?**
R: Sí, pero Bedrock NO está en Free Tier — pagas los tokens. Los otros servicios (Lambda, S3, etc.) sí están en Free Tier para volúmenes de taller.

**P: ¿Cómo cambio el `WORKSHOP_PASSWORD`?**
R: `WORKSHOP_PASSWORD='OtraPassword' bash create-students.sh`. Recuerda regenerar `students.csv`.

**P: ¿Qué pasa si quiero menos / más usuarios?**
R: `NUM_USERS=30 bash create-students.sh`. Los crea idempotentemente.

## Verificación pre-evento (recomendado)

`create-students.sh` ya crea automáticamente un usuario llamado **`ponente-test`** con el mismo boundary y password que los estudiantes — exactamente para esto. Simula como participante:

```bash
# 1. (Ya hecho por create-students.sh) → existe el usuario ponente-test.

# 2. Logout de tu sesion admin.
# 3. Login con ponente-test + la password generica en el login URL.
# 4. Abre CloudShell.
# 5. Dentro de CloudShell:
git clone https://github.com/AndresDFX/bedrock-agents-workshop.git
cd bedrock-agents-workshop
bash deploy.sh
# 6. Verifica que el output diga: Modo: multi-tenant (sufijo='ponente-test')
bash test.sh trace 2     # validar tools encadenadas
bash test.sh rag 2       # validar Knowledge Base
bash destroy.sh          # limpiar solo el stack de ponente-test
```

Si esto funciona end-to-end, los 60 usuarios reales también funcionarán.

**El usuario `ponente-test` se conserva por defecto** después del evento (por si quieres revalidar). Para borrarlo al final:

```bash
DELETE_TEST_USER=true bash destroy-students.sh
```

Variables para personalizar:
- `NUM_USERS=30 bash create-students.sh` → 30 estudiantes en vez de 60.
- `CREATE_TEST_USER=false bash create-students.sh` → no crear `ponente-test`.
- `TEST_USER_NAME=mi-test bash create-students.sh` → cambia el nombre del usuario de prueba.
