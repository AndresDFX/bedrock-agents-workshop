# Más allá del Chatbot: Agente Autónomo de Soporte con Amazon Bedrock

¡Bienvenido al taller práctico! Construirás un **Agente de IA Autónomo** para
soporte al cliente que verifica pedidos, procesa reembolsos y consulta un
catálogo de productos — todo sin que le digas explícitamente qué pasos seguir.

La gran diferencia con un chatbot normal: el agente **decide por sí solo** qué
herramientas usar y en qué orden, encadenando múltiples acciones para resolver
tu solicitud de principio a fin.

Usaremos **Amazon Bedrock Agents** con **Claude Haiku 4.5** y desplegaremos toda
la infraestructura con **AWS CloudFormation**.

---

## ¿Qué diferencia a un Agente de un Chatbot?

| Chatbot tradicional | Agente Autónomo (este taller) |
|---|---|
| Responde con texto generado | Ejecuta acciones reales |
| Tú defines el flujo | El modelo decide el flujo |
| Una llamada al modelo por turno | Puede hacer múltiples llamadas a herramientas |
| Conocimiento estático | Consulta datos en tiempo real |

---

## Prerrequisito Único

- Una cuenta de AWS activa.
  (Trabajaremos **100% en la nube** usando **AWS CloudShell**, sin instalar nada local).

---

# Paso 0: Preparación del Entorno

## 0.1 Habilitar acceso a Claude Haiku 4.5 en Amazon Bedrock

1. En la barra de búsqueda de la consola de AWS, escribe **Amazon Bedrock**.
2. En el menú lateral, entra a **Model catalog**.
3. Busca y selecciona **Claude Haiku 4.5**.
4. Haz clic en **Open in Playground**.
5. Completa el formulario de uso con algo como:

```
Educational purposes for an autonomous agents workshop
```

El modelo quedará habilitado para tu cuenta.

### ⚠️ Nota sobre facturación

Recibirás un correo automático con asunto **"You accepted an AWS Marketplace offer"**.
El costo inicial será **$0.00**. Solo se cobrarán fracciones de centavo por las
peticiones del taller.

---

## 0.2 Abrir AWS CloudShell

1. En la consola de AWS, haz clic en el ícono de terminal **CloudShell** (barra superior).
2. Espera a que cargue el entorno (ya trae `aws`, `git`, `zip` y `jq` preinstalados).

---

## 0.3 Descargar el código del taller

```bash
git clone https://github.com/TU_USUARIO/bedrock-agents-workshop.git
cd bedrock-agents-workshop
```

---

# Estructura del Proyecto

```
.
├── template.yaml          → Infraestructura CloudFormation (roles, Lambda, Agente)
├── deploy.sh              → Script único: empaqueta y despliega todo
├── destroy.sh             → Script único: elimina todos los recursos
├── test.sh                → Script de pruebas (3 escenarios)
└── src/
    └── lambda_function.py → Herramientas del agente (lógica Python)
```

---

# Paso 1: Entendiendo el Código del Agente

## 1.1 Las Herramientas (`src/lambda_function.py`)

La Lambda actúa como el **ejecutor de herramientas** del agente. Implementa tres funciones:

| Herramienta | Qué hace |
|---|---|
| `verificar_pedido` | Consulta el estado y elegibilidad de reembolso |
| `procesar_reembolso` | Aprueba el reembolso si el pedido es elegible |
| `consultar_producto` | Devuelve precio, stock y especificaciones |

## 1.2 La Infraestructura (`template.yaml`)

El template CloudFormation crea los recursos necesarios:

1. **IAM Role (Lambda)** — permisos para ejecutar la función y escribir logs
2. **Lambda Function** — las herramientas que ejecuta el agente
3. **Lambda Permission** — autoriza a Bedrock a invocar la Lambda
4. **IAM Role (Bedrock Agent)** — permite al agente invocar el modelo de IA
5. **Bedrock Agent** — el orquestador que razona y decide qué herramientas usar
6. **Bedrock Agent Alias** — endpoint estable para invocar el agente

💡 **Nota arquitectónica:** El rol del agente DEBE llamarse
`AmazonBedrockExecutionRoleForAgents_*` — es un requisito de AWS Bedrock.

---

# Paso 2: Desplegar la Infraestructura

Un único comando empaqueta la Lambda, sube el ZIP a S3 y lanza el stack:

```bash
bash deploy.sh
```

El script:

1. Crea (si no existe) el bucket `workshop-agentes-<ACCOUNT_ID>`.
2. Empaqueta `src/lambda_function.py` en `lambda.zip`.
3. Sube el ZIP a S3.
4. Ejecuta `aws cloudformation deploy` con el stack `agente-soporte`.
5. Genera `agent.env` con `AGENT_ID` y `ALIAS_ID` listos para usar.

El despliegue tarda ~2-3 minutos. Al terminar, carga las variables en tu shell:

```bash
source agent.env
```

---

# Paso 3: Probar el Agente Autónomo

El agente se invoca con lenguaje natural. Observa cómo encadena herramientas
automáticamente sin que tú se las indiques.

## Atajo: ejecutar los 3 escenarios de un solo golpe

```bash
bash test.sh
```

También puedes correr un escenario individual: `bash test.sh 1`, `bash test.sh 2`
o `bash test.sh 3`. Si prefieres ver los comandos completos, sigue con las
secciones 3.1 a 3.3.

## 3.1 Consulta simple (1 herramienta)

```bash
aws bedrock-agent-runtime invoke-agent \
  --agent-id ${AGENT_ID} \
  --agent-alias-id ${ALIAS_ID} \
  --session-id "sesion-$(date +%s)" \
  --input-text "¿Cuánto cuesta el monitor y cuántos hay en stock?" \
  --region ${AWS_REGION} \
  respuesta.json && cat respuesta.json
```

## 3.2 Flujo multi-paso autónomo (2 herramientas encadenadas)

Aquí el agente verificará el pedido ANTES de procesar el reembolso — sin que
se lo pidas explícitamente:

```bash
aws bedrock-agent-runtime invoke-agent \
  --agent-id ${AGENT_ID} \
  --agent-alias-id ${ALIAS_ID} \
  --session-id "sesion-$(date +%s)" \
  --input-text "Quiero un reembolso para mi pedido ORD-1001 porque el producto llegó dañado" \
  --region ${AWS_REGION} \
  respuesta.json && cat respuesta.json
```

**¿Qué hace el agente internamente?**

```
1. Recibe: "Quiero un reembolso para el pedido ORD-1001..."
2. Razona: "Debo verificar si es elegible antes de procesar"
3. Llama:  verificar_pedido(numero_pedido="ORD-1001")
4. Ve:     "Entregado hace 5 días → ELEGIBLE"
5. Llama:  procesar_reembolso(numero_pedido="ORD-1001", motivo="producto llegó dañado")
6. Responde: "Tu reembolso de $1299.99 fue aprobado..."
```

## 3.3 Pedido no elegible (lógica de negocio autónoma)

```bash
aws bedrock-agent-runtime invoke-agent \
  --agent-id ${AGENT_ID} \
  --agent-alias-id ${ALIAS_ID} \
  --session-id "sesion-$(date +%s)" \
  --input-text "Necesito reembolso del pedido ORD-1004" \
  --region ${AWS_REGION} \
  respuesta.json && cat respuesta.json
```

El agente detectará que han pasado 45 días y rechazará el reembolso con una
explicación clara — todo de forma autónoma.

---

# Paso 4: Destruir los Recursos (Evitar Costos)

```bash
bash destroy.sh
```

Esto elimina el stack de CloudFormation, vacía y borra el bucket S3, y limpia
los archivos locales (`lambda.zip`, `agent.env`).

---

## Resultado

Has construido un **Agente Autónomo de IA** capaz de:

- Razonar sobre qué herramientas usar en cada situación
- Encadenar múltiples llamadas sin instrucciones explícitas
- Aplicar reglas de negocio de forma inteligente
- Responder en lenguaje natural a solicitudes complejas

Tecnologías utilizadas:

- Amazon Bedrock Agents
- Claude Haiku 4.5 (Cross-Region Inference Profile)
- AWS Lambda (Action Group Handler)
- AWS CloudFormation (IaC)
- AWS IAM

---

Desarrollado con ☁️ para AWS Community Day.
