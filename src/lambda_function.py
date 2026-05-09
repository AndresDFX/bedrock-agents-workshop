import json

# Datos simulados de TechStore para el taller
PEDIDOS = {
    "ORD-1001": {"estado": "Entregado",   "producto": "Laptop UltraBook 15",  "precio": 1299.99, "dias_desde_entrega": 5,  "elegible_reembolso": True},
    "ORD-1002": {"estado": "En tránsito", "producto": "Mouse Inalámbrico Pro", "precio": 45.99,  "dias_desde_entrega": 0,  "elegible_reembolso": False},
    "ORD-1003": {"estado": "Procesando",  "producto": "Teclado Mecánico RGB",  "precio": 89.99,  "dias_desde_entrega": 0,  "elegible_reembolso": False},
    "ORD-1004": {"estado": "Entregado",   "producto": "Monitor 4K 27\"",       "precio": 599.99, "dias_desde_entrega": 45, "elegible_reembolso": False},
}

PRODUCTOS = {
    "laptop":   {"nombre": "Laptop UltraBook 15",   "precio": 1299.99, "stock": 12, "garantia": "2 años",  "descripcion": "Intel Core i7, 16GB RAM, 512GB SSD, Windows 11"},
    "mouse":    {"nombre": "Mouse Inalámbrico Pro",  "precio": 45.99,   "stock": 45, "garantia": "1 año",   "descripcion": "Bluetooth 5.0, batería de 6 meses, 3 botones programables"},
    "teclado":  {"nombre": "Teclado Mecánico RGB",   "precio": 89.99,   "stock": 8,  "garantia": "1 año",   "descripcion": "Switches Cherry MX Red, retroiluminación RGB, anti-ghosting"},
    "monitor":  {"nombre": "Monitor 4K 27\"",        "precio": 599.99,  "stock": 3,  "garantia": "3 años",  "descripcion": "Panel IPS, 144Hz, HDR400, 1ms tiempo de respuesta"},
}


def verificar_pedido(numero_pedido: str) -> str:
    pedido = PEDIDOS.get(numero_pedido.upper())
    if not pedido:
        return f"No encontré el pedido {numero_pedido}. Verifica el número e intenta de nuevo (formato: ORD-XXXX)."

    estado = pedido["estado"]
    producto = pedido["producto"]
    precio = pedido["precio"]
    dias = pedido["dias_desde_entrega"]
    elegible = pedido["elegible_reembolso"]

    info = f"Pedido {numero_pedido}: '{producto}' | Estado: {estado} | Precio pagado: ${precio:.2f}"

    if estado == "Entregado":
        info += f" | Entregado hace {dias} días"
        info += " | ELEGIBLE para reembolso" if elegible else " | NO elegible para reembolso (más de 30 días)"
    return info


def procesar_reembolso(numero_pedido: str, motivo: str) -> str:
    pedido = PEDIDOS.get(numero_pedido.upper())
    if not pedido:
        return f"No encontré el pedido {numero_pedido}."

    if pedido["estado"] != "Entregado":
        return f"No se puede reembolsar: el pedido {numero_pedido} aún no ha sido entregado (estado: {pedido['estado']})."

    if not pedido["elegible_reembolso"]:
        return f"No se puede reembolsar: han pasado más de 30 días desde la entrega del pedido {numero_pedido}."

    precio = pedido["precio"]
    return (
        f"Reembolso APROBADO para {numero_pedido} por ${precio:.2f}. "
        f"Motivo registrado: '{motivo}'. "
        f"El monto se acreditará en 3-5 días hábiles a tu método de pago original."
    )


def consultar_producto(nombre_producto: str) -> str:
    clave = nombre_producto.lower()
    for key, producto in PRODUCTOS.items():
        if key in clave:
            return (
                f"Producto: {producto['nombre']} | "
                f"Precio: ${producto['precio']:.2f} | "
                f"Stock: {producto['stock']} unidades disponibles | "
                f"Garantía: {producto['garantia']} | "
                f"Especificaciones: {producto['descripcion']}"
            )
    return f"No encontré información sobre '{nombre_producto}'. Productos disponibles: Laptop, Mouse, Teclado, Monitor."


def lambda_handler(event, context):
    action_group = event.get("actionGroup", "")
    function = event.get("function", "")
    parameters = {p["name"]: p["value"] for p in event.get("parameters", [])}

    if function == "verificar_pedido":
        result = verificar_pedido(parameters.get("numero_pedido", ""))
    elif function == "procesar_reembolso":
        result = procesar_reembolso(
            parameters.get("numero_pedido", ""),
            parameters.get("motivo", "sin motivo especificado")
        )
    elif function == "consultar_producto":
        result = consultar_producto(parameters.get("nombre_producto", ""))
    else:
        result = f"Función '{function}' no reconocida en el action group '{action_group}'."

    # Formato de respuesta requerido por Bedrock Agents
    return {
        "messageVersion": "1.0",
        "response": {
            "actionGroup": action_group,
            "function": function,
            "functionResponse": {
                "responseBody": {
                    "TEXT": {"body": result}
                }
            }
        }
    }
