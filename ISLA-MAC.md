# Codenotch — Isla dinámica en Mac (Map Ranking)

Una «isla dinámica» estilo iPhone para la app de Mac de [Codenotch](https://github.com/vinzdg/codenotch) (MIT),
portada de un build propio para Windows (Rust/Tauri, no incluido aquí). Todo lo nuevo vive en `Sources/Island/`;
del original solo se tocan unas líneas (ver «Cambios fuera de Sources/Island»), para poder seguir integrando
versiones nuevas de upstream sin conflictos. Instalación para usuarios: `LEEME-mac.txt`.

## Qué se portó

| Windows (Rust/Tauri) | Mac (Swift) | Notas |
|---|---|---|
| Isla plegada / abierta al hover (`notch.html`) | `IslandController.swift` + `IslandViews.swift` | Ventana `NSPanel` transparente propia; fuera de la isla los clics pasan (mismo patrón que `NotchHostingView`). |
| Isla dividida 30/70 | `IslandLayout.swift` (`musicShare = 0.3`) | Una sola geometría para la vista, el mouse y las pruebas. |
| `media.rs` (controles multimedia de Windows) | `NowPlaying.swift` (AppleScript a Spotify y Música) | MediaRemote no responde a terceros desde macOS 15.4: navegadores no se ven. |
| `lyrics.rs` (LRCLIB) | `IslandLyrics.swift` | Misma búsqueda, mismo criterio de «mejor entrada», mismas pruebas. |
| `sysmetrics.rs` | `IslandSystem.swift` | `host_statistics` (CPU), `host_statistics64` (RAM como el Monitor de Actividad), volúmenes locales. |
| `bluetooth.rs` | `IslandBluetooth.swift` | IOBluetooth + batería por métodos internos de `IOBluetoothDevice` (audífonos Apple) y `BatteryPercent` de IOKit (teclados/ratones). |
| `capture.rs` | `IslandCapture.swift` | `screencapture` (pantalla completa / recorte) y la app Captura de pantalla (grabar). |
| `glass.rs` (vidrio fingido con capturas) | `IslandGlass` | Nativo: Liquid Glass en macOS 26, `NSVisualEffectView` en macOS 15. |
| `island.rs` + pestaña de `settings.html` | `IslandSettings.swift` + `IslandSettingsPane.swift` | `UserDefaults` `isla.*`; pestaña «Isla dinámica» en Configuración. |
| Color propio, presets | `IslandColor` | Mismo formato `#RRGGBB`. |

No se portó: ventiladores (HP OMEN/Windows), la isla en los bordes izquierdo/derecho/abajo (en Mac va arriba,
fundida con el notch físico), el arrastre de la isla y `carry.html`.

## Cómo encaja con el notch

- Los anillos de IA son los del propio Codenotch: la isla lee `NotchFleet.menuModel`, que recibe todas las lecturas.
- Con la isla encendida y el notch clásico en el borde de arriba, el notch se oculta (`NotchVisibility.hidden`,
  decidido en `AppDelegate` con `IslandController.replacesNotch`). En otro borde conviven.
- El engranaje de la isla abre Configuración; tocar un anillo de IA usa `fleet.onRefreshProvider`; abrirla llama a
  `fleet.onLook`.

## Cambios fuera de Sources/Island

- `Sources/App/AppDelegate.swift`: propiedad `island`, el `sink` de visibilidad del notch y el arranque de la isla
  después de `fleet.show()`.
- `Sources/Settings/SettingsView.swift`: caso `island` en `SettingsSection`.
- `project.yml` + `Sources/Info.plist`: `NSAppleEventsUsageDescription`, `NSBluetoothAlwaysUsageDescription` y
  `SUEnableAutomaticChecks: false` (la actualización oficial borraría la isla).
- `Makefile` (`build-ci`): entitlement `com.apple.security.automation.apple-events` (el hardened runtime bloquea
  AppleScript sin él).
- `.github/workflows/isla-mac.yml`: compila en `macos-26`, sube el `.dmg`, corre las pruebas y publica el `.dmg`
  en Releases (etiqueta `isla-mac`).

## Compilar

No hace falta una Mac: el workflow **Isla Mac** corre con cada push a `main` que toque la app (o a mano desde
Actions) y deja el `.dmg` en [Releases](../../releases/latest).

En una Mac con Xcode 26: `brew install xcodegen create-dmg`, luego `make dmg-ci` (app sin firmar en
`build/ci/`) y `make test-ci`. Pruebas de la isla: `Tests/IslandTests.swift`.

## Actualizar desde el original

```bash
git fetch upstream --tags
git switch main
git merge vX.Y.Z
```

Conflictos esperables solo en las líneas de arriba. `Sources/Island/` no existe upstream.
