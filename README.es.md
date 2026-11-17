# ADFlow

[![CI](https://github.com/DavidGoRi/ADFlow/actions/workflows/ci.yml/badge.svg)](https://github.com/DavidGoRi/ADFlow/actions/workflows/ci.yml)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-blue)
![Licencia: MIT](https://img.shields.io/badge/licencia-MIT-green)

*Read in [English](README.md).*

**Altas y bajas de usuarios automatizadas en Active Directory, escritas en PowerShell.**

RR. HH. envía un CSV con las personas que se incorporan el mes que viene. ADFlow
convierte cada fila en una cuenta lista para usar: un nombre de usuario único, la
OU de su departamento, los grupos de su puesto y una contraseña temporal que hay
que cambiar en el primer inicio de sesión. Cada acción queda registrada con lo
necesario para deshacerla.

> **Estado: fase 1 de 5.** Las altas funcionan de principio a fin contra un
> directorio simulado. Después llegan las bajas, la reversión, las carpetas
> personales, el informe HTML y el proveedor real de Active Directory (ver la
> [hoja de ruta](#hoja-de-ruta)).

## Por qué está hecho así

La lógica nunca llama directamente al módulo ActiveDirectory. Habla con un
**proveedor de directorio**, un objeto pequeño con métodos como `FindUser`,
`NewUser` y `AddGroupMember`. Hay dos implementaciones:

| Proveedor | Para qué | Estado |
| --- | --- | --- |
| `Mock` | tests, la demo y cualquier PC sin dominio | listo |
| `ActiveDirectory` | un dominio real, con RSAT (`New-ADUser`, `Add-ADGroupMember`…) | fase 4 |

Así, todas las reglas (nombres, OU, grupos, validación, idempotencia y registro) se
prueban con Pester en un Windows normal y en GitHub Actions, sin controlador de
dominio.

```
CSV de RR. HH. ──► Import-ADFlowHireFile ──► Invoke-ADFlowOnboarding ──► proveedor de directorio
                    (validación)               │  Get-ADFlowSamAccountName     ├─ Mock (JSON)
                                               │  Get-ADFlowDepartmentOu       └─ ActiveDirectory (fase 4)
configuración ──► Get-ADFlowConfig ────────────┤  Get-ADFlowGroupAssignment
                                               │  Get-ADFlowRandomPassword
                                               └─► auditoría: audit.jsonl, audit.csv, summary.json
```

## Funciones (fase 1)

- **Nombres de usuario únicos.** `María José García López` → `maria.garcia`. Si
  está ocupado: `maria.garcial` (inicial del segundo apellido), después
  `maria.garcia2`, `maria.garcia3`… Quita tildes y letras especiales (`Íñigo` →
  `inigo`, `Groß` → `gross`), mantiene las partículas con su apellido (`de la
  Fuente` → `delafuente`), une guiones y apóstrofos (`O'Connor` → `oconnor`) y
  respeta el límite de 20 caracteres de `sAMAccountName` sin perder el número
  final. También evita los nombres asignados antes en la misma ejecución.
- **OU según el departamento y grupos según el puesto**, desde un JSON. La
  comparación no distingue mayúsculas, tildes ni espacios de más. Los
  departamentos desconocidos se rechazan; los puestos desconocidos reciben solo
  los grupos por defecto, con un aviso.
- **Contraseñas temporales seguras** de un generador criptográfico, con
  mayúsculas, minúsculas, números y símbolos, y sin caracteres que se confunden
  (`O/0`, `I/l/1`). Solo se devuelven como `SecureString` y nunca se escriben en
  disco. Las cuentas se crean con *cambiar la contraseña en el siguiente inicio
  de sesión*.
- **Validación del CSV de RR. HH.**: separado por comas o por punto y coma (Excel
  en español usa `;`), UTF-8, columnas obligatorias, identificadores repetidos o
  mal formados y fechas no válidas. Una fila errónea no detiene las demás.
- **Idempotente**: si el `EmployeeId` ya está en el directorio, la persona se
  omite, así que el mismo archivo se puede ejecutar dos veces sin riesgo.
- **Tres modos**: `-DryRun` (calcula todo el plan y lo registra como *Planned*),
  el `-WhatIf` estándar y el modo real.
- **Auditoría** de cada ejecución en `output\runs\<RunId>\`: `audit.jsonl` (se
  escribe sobre la marcha), `audit.csv` y `summary.json`. Cada cambio lleva su
  acción inversa (`RemoveUser`, `RemoveGroupMember`) para la reversión de la fase 2.

## Inicio rápido

Requisitos: Windows PowerShell 5.1 (incluido en Windows 10/11). No hace falta nada
más para probarlo: la demo usa el directorio simulado.

```powershell
git clone https://github.com/DavidGoRi/ADFlow.git
cd ADFlow

# Ver qué pasaría, sin cambiar nada
.\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv -DryRun

# Crear las cuentas en el directorio simulado (output\mock-directory.json)
.\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv -ResetMockDirectory
```

Simulación con el archivo de la demo (todos los nombres y datos son ficticios):

```
Planned   E1001   maria.garcial         María José García López
Planned   E1002   jose.pena             José Ángel Peña Muñoz
Planned   E1003   pedro.delafuente      Pedro de la Fuente Ruiz
          Group GG-CRM-Users does not exist in the directory and was not assigned
Planned   E1004   inigo.martinezaragon  Íñigo Martínez-Aragón
Planned   E1005   ana.garcia2           Ana García Lorenzo
Planned   E1006   zoe.oconnor           Zoë O'Connor
          Title 'Brand Manager' has no role in the settings: only the default groups are given
Planned   E1007   maximiliano.fernande  Maximiliano Fernández-Villaverde
          Group GG-CRM-Users does not exist in the directory and was not assigned; Manager javier.moreno not found: the account has no manager
Rejected  E1008   -                     Lucía Gómez
          Department 'Legal' has no OU in the settings
Rejected  E1002   -                     José Peña
          EmployeeId 'E1002' is repeated (first on row 3)
Skipped   E0907   laura.sanchez         Laura Sánchez Ortega
          Employee E0907 already has the account laura.sanchez
Rejected  E1009   -                     Sofía
          LastName is empty; StartDate '2026-13-01' is not a yyyy-MM-dd date
Planned   E1010   jose.penam            José Ángel Peña Moreno

Run 20261117-174252-2246: 8 Planned, 3 Rejected, 1 Skipped
```

Los mensajes del programa están en inglés, como el código.

### Parámetros de `ADFlow.ps1`

| Parámetro | Por defecto | Descripción |
| --- | --- | --- |
| `-Action` | | `Onboard` (más acciones en las siguientes fases) |
| `-CsvPath` | | CSV de RR. HH. con las altas |
| `-ConfigPath` | `config\adflow.json` | Dominio, OU, puestos y grupos |
| `-Provider` | `Mock` | Proveedor de directorio |
| `-MockSeedPath` | `demo\directory.json` | Estado inicial del directorio simulado |
| `-MockStatePath` | `output\mock-directory.json` | Dónde guarda sus cambios el directorio simulado |
| `-LogPath` | `output\runs` | Carpeta de la auditoría |
| `-DryRun` | | Solo el plan, sin cambios |
| `-WhatIf` | | Vista previa estándar de PowerShell |
| `-ResetMockDirectory` | | Vuelve a empezar el directorio simulado desde el estado inicial |
| `-PassThru` | | Devuelve los resultados (contraseñas como `SecureString`) |

## CSV de RR. HH.

CSV en UTF-8 con cabecera, separado por `,` o `;`:

```
EmployeeId;FirstName;LastName;Department;Title;Manager;StartDate
E1001;María José;García López;IT;Helpdesk Technician;laura.sanchez;2026-12-01
```

| Columna | Obligatoria | Notas |
| --- | --- | --- |
| `EmployeeId` | sí | De 1 a 16 letras, números o guiones; único en el archivo |
| `FirstName`, `LastName` | sí | Nombre y apellidos completos, con tildes; dos apellidos sin problema |
| `Department` | sí | Debe existir en la configuración |
| `Title` | sí | Puesto; los desconocidos reciben solo los grupos por defecto |
| `Manager` | no | `sAMAccountName` del responsable |
| `StartDate` | no | `yyyy-MM-dd` |

## Configuración

[`config/adflow.json`](config/adflow.json) relaciona departamentos con OU y puestos
con grupos:

```json
{
  "domain": { "upnSuffix": "corp.example.com", "mailDomain": "corp.example.com" },
  "naming": { "maxLength": 20 },
  "password": { "length": 16 },
  "defaultGroups": [ "GG-AllStaff" ],
  "departments": {
    "IT": { "ou": "OU=IT,OU=Staff,DC=corp,DC=example,DC=com" }
  },
  "roles": {
    "Helpdesk Technician": [ "GG-IT-Helpdesk", "GG-VPN-Users" ]
  }
}
```

El archivo se valida al cargarlo y se informa de todos los problemas a la vez.

## Auditoría

Cada ejecución escribe una carpeta `output\runs\<aaaaMMdd-HHmmss-xxxx>\`:

```json
{"timestamp":"2026-11-17T17:43:00.4011501+01:00","runId":"20261117-174300-56fe","sequence":1,
 "action":"CreateUser","target":"maria.garcial","employeeId":"E1001","status":"Succeeded","message":"",
 "details":{"SamAccountName":"maria.garcial","Ou":"OU=IT,OU=Staff,DC=corp,DC=example,DC=com","...":"..."},
 "undo":{"Action":"RemoveUser","SamAccountName":"maria.garcial"}}
```

Estados: `Succeeded`, `Failed`, `Planned` (simulación), `WhatIf`, `Skipped` y
`Rejected`. El registro rechaza cualquier dato llamado `Password` o que sea un
`SecureString`. `output\` está en `.gitignore`: en un uso real contiene datos
personales.

## Tests

130 tests de Pester cubren la generación de nombres, las contraseñas, la
configuración, la validación del CSV, el directorio simulado, la auditoría, los
tres modos, los fallos del directorio y el script de entrada. También comprueban
que todos los scripts están en UTF-8 con BOM (Windows PowerShell 5.1 lo necesita
para leer bien las tildes) y que los datos de ejemplo solo usan el dominio
reservado `example.com`.

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser

Invoke-Pester -Path .\tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

GitHub Actions ejecuta ambos en Windows PowerShell 5.1 con cada *push*.

## Hoja de ruta

1. **Núcleo y altas** ✅: capa de proveedor y directorio simulado, nombres
   únicos, OU y grupos, contraseñas, validación del CSV, `-DryRun`/`-WhatIf`,
   auditoría, tests y CI.
2. **Bajas y reversión**: deshabilitar la cuenta, quitarle los grupos y
   guardarlos en el registro, y moverla a la OU de bajas; `Undo-ADFlowRun` aplica
   las entradas `undo` de una ejecución en orden inverso.
3. **Carpetas personales, correo de bienvenida e informe**: carpeta personal con
   permisos NTFS, mensaje de bienvenida desde una plantilla (se genera, no se
   envía) e informe HTML de cada ejecución.
4. **Proveedor de Active Directory y laboratorio**: los mismos métodos sobre
   RSAT y una guía para montar un dominio de pruebas con Windows Server
   Evaluation en Hyper-V.
5. **Pulido**: capturas, registro de cambios y versión 1.0.0.

## Estructura

```
ADFlow.ps1                 punto de entrada
config/adflow.json         configuración de ejemplo (dominio ficticio)
demo/new-hires.csv         CSV de RR. HH. de ejemplo
demo/directory.json        estado inicial del directorio simulado
src/Naming.ps1             tildes y nombres de usuario únicos
src/Password.ps1           contraseñas temporales
src/Config.ps1             configuración, departamentos y puestos
src/HRFile.ps1             lectura y validación del CSV de RR. HH.
src/MockDirectory.ps1      proveedor de directorio simulado
src/Audit.ps1              auditoría
src/Onboarding.ps1         altas
tests/                     tests de Pester
```

## Licencia

[MIT](LICENSE). Todas las personas, identificadores y dominios de este repositorio
son ficticios.
