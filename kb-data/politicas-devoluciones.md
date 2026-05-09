# TechStore — Política de devoluciones y reembolsos (vigente 2026)

## Resumen

- **Plazo general:** 30 días calendario desde la entrega.
- **Producto en caja sellada y sin abrir:** reembolso al 100% o cambio sin penalidad.
- **Producto abierto en buen estado:** reembolso al 90%; el 10% restante cubre
  reacondicionamiento, embalaje y verificación técnica.
- **Producto dañado en tránsito:** reembolso al 100% sin penalidad. El cliente
  debe reportarlo dentro de las primeras 72 horas tras la entrega.
- **Producto con falla de fábrica dentro de los 30 días:** reembolso al 100%
  o reemplazo, a elección del cliente.

## Pasos para iniciar una devolución

1. Tener el número de pedido en formato `ORD-XXXX`.
2. Conservar el empaque original siempre que sea posible.
3. Adjuntar fotos del producto y del empaque si corresponde.
4. Solicitar la devolución por el chat del agente o en
   `https://techstore.example/soporte/devoluciones` (URL ficticia para el
   taller).

## Excluido de devolución

- Pedidos entregados hace más de 30 días (sin excepciones, salvo garantía
  vigente — ver `politicas-garantia.md`).
- Productos personalizados (grabados, configuraciones a medida).
- Software descargado y activado, salvo que esté defectuoso.
- Consumibles abiertos (cartuchos, baterías ya usadas, audífonos in-ear con
  almohadillas usadas).

## Tiempo de acreditación del reembolso

- **Tarjeta de crédito o débito:** 3 a 5 días hábiles tras aprobación.
- **PSE / transferencia bancaria:** 1 a 3 días hábiles.
- **Mercado Pago / billetera digital:** 24 horas.
- **TechCoins (programa de fidelidad):** acreditación inmediata, ver
  `programa-fidelidad.md`.

## Casos de "elegibilidad" automática

El agente y el sistema interno marcan un pedido como **ELEGIBLE para
reembolso** cuando se cumplen TODAS las condiciones:

- Estado del pedido = `Entregado`.
- Días desde la entrega ≤ 30.
- El cliente no ha solicitado previamente reembolso para ese mismo pedido.
- Motivo proporcionado por el cliente.

Si una de estas condiciones falla, el reembolso se rechaza automáticamente con
una explicación. La verificación se realiza con la herramienta
`verificar_pedido` antes de ejecutar `procesar_reembolso`.
