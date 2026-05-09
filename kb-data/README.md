# Datos seed de la Knowledge Base — TechStore

Esta carpeta se sube a S3 (`s3://workshop-agentes-<ACCOUNT>/kb-data/`) y se
indexa en una **Bedrock Knowledge Base** con almacenamiento vectorial en
**S3 Vectors** (embeddings con `amazon.titan-embed-text-v2:0`, 1024 dim,
distancia coseno).

> Todos los datos son **ficticios** y existen únicamente para demostrar RAG en
> el taller. La marca *TechStore*, sus políticas, productos, sucursales y
> programas de fidelidad NO representan a una compañía real.

## Estructura

| Archivo | Tipo de contenido | Para qué sirve en la demo |
|---|---|---|
| `politicas-devoluciones.md` | "Real-ish" (políticas creíbles) | Pregunta el cliente por reglas de reembolso → el agente cita la KB |
| `politicas-garantia.md` | "Real-ish" | Cobertura de garantía por categoría |
| `politicas-envio.md` | "Real-ish" | Tiempos de envío y costos |
| `metodos-pago.md` | "Real-ish" | Tarjetas, PSE, Mercado Pago, etc. |
| `faq-soporte.md` | "Real-ish" | Preguntas frecuentes; incluye **resumen TechCoins al inicio** para mejorar la recuperación vectorial |
| `techcoins-resumen.md` | **Inventado** (compacto) | Tabla Q/A densa + keywords; apunta a `programa-fidelidad.md` para detalle |
| `catalogo-detallado.md` | Mezcla — extiende los productos que la Lambda ya conoce | El agente combina **tools (Lambda)** + **RAG** |
| `info-empresa.md` | **Inventado** | Demuestra que el RAG **respeta** el contenido del KB aunque sea inventado |
| `programa-fidelidad.md` | **Inventado** ("TechCoins") | Reglas completas + TL;DR al inicio del archivo |
| `sucursales.md` | **Inventado** | Direcciones físicas — útil para preguntar por algo que **no** está |

## Cómo distinguir los dos modos en la charla

1. **Pregunta cosas que SÍ están en la KB** → el agente responderá con detalles
   muy específicos (ej. "¿qué cubre la garantía del monitor?").
2. **Pregunta algo que NO está** (ej. "¿tienen sucursal en Lima?") → el agente
   debería decir que no tiene esa información, en lugar de inventar.
3. **Combinación con tools** → "¿Es elegible mi pedido ORD-1001 según la
   política?" mezclará `verificar_pedido` (Lambda) con la KB (política de 30 días).
