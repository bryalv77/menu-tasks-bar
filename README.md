# Menu Tasks Bar

App de barra de menús para macOS que muestra y gestiona tus **Google Tasks**. Escrita en Swift/SwiftUI, sin dependencias externas.

- Listas, tareas y subtareas de Google Tasks, con caché local para abrir al instante.
- Favoritas y hora del día (solo en tu Mac: la API de Google no las soporta).
- Contador de pendientes en el icono, sincronización cada 30 s con el panel abierto y cada 5 min en segundo plano.
- Opción de iniciar con el Mac.

Requiere macOS 13 o superior.

## Privacidad y seguridad

- Inicio de sesión con OAuth 2.0 + PKCE mediante `ASWebAuthenticationSession`. No usa client secret.
- Pide solo el permiso `https://www.googleapis.com/auth/tasks`.
- Los tokens se guardan en el Keychain; la caché de tareas en un archivo de uso exclusivo del usuario (0600).
- App Sandbox con acceso de red como único permiso (`Resources/TasksBar.entitlements`).
- La app solo habla con los servidores de Google. No hay telemetría.

## Compilar

Necesitas Xcode (o las Command Line Tools) con Swift 5.9+ y tu propio OAuth Client ID de Google.

### 1. Crea el Client ID

1. En [Google Cloud Console](https://console.cloud.google.com/) crea un proyecto y activa la **Google Tasks API**.
2. Configura la pantalla de consentimiento de OAuth y añade el scope `.../auth/tasks`.
3. Crea unas credenciales **OAuth client ID** de tipo **iOS** con el bundle ID `com.devalv.MenuTasksBar` (o el tuyo, si lo cambias en `Resources/Info.plist`).
4. Descarga el `.plist` y guárdalo en la raíz del repo como `client.plist`. Está en `.gitignore`.

> Mientras la pantalla de consentimiento esté en modo "Testing", solo entran los usuarios de prueba que añadas y los tokens caducan a los 7 días.

### 2. (Opcional) Firma estable

Por defecto el script firma ad-hoc, y con eso el Keychain vuelve a pedir permiso en cada compilación. Para evitarlo, firma siempre con el mismo certificado:

```sh
cp .env.example .env     # edita SIGN_ID con tu certificado
```

`.env` está en `.gitignore`. Para distribuir fuera de tu Mac necesitas un certificado *Developer ID Application* y, para notarizar, `NOTARY_PROFILE` (ver `.env.example`).

### 3. Compila

```sh
./scripts/build.sh              # genera build/TasksBar.app
UNIVERSAL=1 ./scripts/build.sh  # arm64 + x86_64
```

Para generar el `.zip` y el `.dmg` de distribución: `./scripts/package.sh` (los deja en `build/`).

`build.sh` lee `CLIENT_ID` de `client.plist` y lo inyecta en el `Info.plist` del `.app`; el Client ID no está en el código.

## Desarrollo

```sh
export TASKSBAR_CLIENT_ID="tu-id.apps.googleusercontent.com"   # swift run no tiene Info.plist
swift run
swift test
```

En builds de debug, `TASKSBAR_FAKE=1 swift run` arranca con datos de demostración, sin iniciar sesión ni tocar tu Keychain o tu caché reales.

## Reportar una vulnerabilidad

Abre un aviso privado desde la pestaña *Security* del repositorio en lugar de un issue público.

## Licencia

[MIT](LICENSE)
